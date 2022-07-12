/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <io/fst/lookup_tables.cuh>
#include <io/utilities/hostdevice_vector.hpp>

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/cudf_gtest.hpp>

#include <cudf/scalar/scalar_factories.hpp>
#include <cudf/strings/repeat_strings.hpp>
#include <cudf/types.hpp>

#include <rmm/cuda_stream.hpp>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_uvector.hpp>

#include <cstdlib>
#include <vector>

namespace {

//------------------------------------------------------------------------------
// CPU-BASED IMPLEMENTATIONS FOR VERIFICATION
//------------------------------------------------------------------------------
/**
 * @brief CPU-based implementation of a finite-state transducer (FST).
 *
 * @tparam InputItT Forward input iterator type to symbols fed into the FST
 * @tparam StateT Type representing states of the finite-state machine
 * @tparam SymbolGroupLutT Sequence container of symbol groups. Each symbol group is a sequence
 * container to symbols within that group.
 * @tparam TransitionTableT Two-dimensional container type
 * @tparam TransducerTableT Two-dimensional container type
 * @tparam OutputItT Forward output iterator type
 * @tparam IndexOutputItT Forward output iterator type
 * @param[in] begin Forward iterator to the beginning of the symbol sequence
 * @param[in] end Forward iterator to one past the last element of the symbol sequence
 * @param[in] init_state The starting state of the finite-state machine
 * @param[in] symbol_group_lut Sequence container of symbol groups. Each symbol group is a sequence
 * container to symbols within that group. The index of the symbol group containing a symbol being
 * read will be used as symbol_gid of the transition and translation tables.
 * @param[in] transition_table The two-dimensional transition table, i.e.,
 * transition_table[state][symbol_gid] -> new_state
 * @param[in] translation_table The two-dimensional transducer table, i.e.,
 * translation_table[state][symbol_gid] -> range_of_output_symbols
 * @param[out] out_tape A forward output iterator to which the transduced input will be written
 * @param[out] out_index_tape A forward output iterator to which indexes of the symbols that
 * actually caused some output are written to
 * @return A pair of iterators to one past the last element of (1) the transduced output symbol
 * sequence and (2) the indexes of
 */
template <typename InputItT,
          typename StateT,
          typename SymbolGroupLutT,
          typename TransitionTableT,
          typename TransducerTableT,
          typename OutputItT,
          typename IndexOutputItT>
static std::pair<OutputItT, IndexOutputItT> fst_baseline(InputItT begin,
                                                         InputItT end,
                                                         StateT const& init_state,
                                                         SymbolGroupLutT symbol_group_lut,
                                                         TransitionTableT transition_table,
                                                         TransducerTableT translation_table,
                                                         OutputItT out_tape,
                                                         IndexOutputItT out_index_tape)
{
  // Initialize "FSM" with starting state
  StateT state = init_state;

  // To track the symbol offset within the input that caused the FST to output
  std::size_t in_offset = 0;
  for (auto it = begin; it < end; it++) {
    // The symbol currently being read
    auto const& symbol = *it;

    std::size_t symbol_group = 0;
    bool found               = false;

    // Iterate over symbol groups and search for the first symbol group containing the current
    // symbol
    for (auto const& sg : symbol_group_lut) {
      for (auto const& s : sg)
        if (s == symbol) found = true;
      if (found) break;
      symbol_group++;
    }

    // Output the translated symbols to the output tape
    size_t inserted = 0;
    for (auto out : translation_table[state][symbol_group]) {
      // std::cout << in_offset << ": " << out << "\n";
      *out_tape = out;
      ++out_tape;
      inserted++;
    }

    // Output the index of the current symbol, iff it caused some output to be written
    if (inserted > 0) {
      *out_index_tape = in_offset;
      out_index_tape++;
    }

    // Transition the state of the finite-state machine
    state = transition_table[state][symbol_group];

    in_offset++;
  }
  return {out_tape, out_index_tape};
}

//------------------------------------------------------------------------------
// TEST FST SPECIFICATIONS
//------------------------------------------------------------------------------
// FST to check for brackets and braces outside of pairs of quotes
// The state being active while being outside of a string. When encountering an opening bracket
// or curly brace, we push it onto the stack. When encountering a closing bracket or brace, we
// pop it from the stack.
constexpr uint32_t TT_OOS = 0U;

// The state being active while being within a string (e.g., field name or a string value). We do
// not push or pop from the stack while being in this state.
constexpr uint32_t TT_STR = 1U;

// The state being active after encountering an escape symbol (e.g., '\') while being in the TT_STR
// state. constexpr uint32_t TT_ESC = 2U; // cmt to avoid 'unused' warning

// Total number of states
constexpr uint32_t TT_NUM_STATES = 3U;

// Definition of the symbol groups
enum PDA_SG_ID {
  OBC = 0U,          ///< Opening brace SG: {
  OBT,               ///< Opening bracket SG: [
  CBC,               ///< Closing brace SG: }
  CBT,               ///< Closing bracket SG: ]
  QTE,               ///< Quote character SG: "
  ESC,               ///< Escape character SG: '\'
  OTR,               ///< SG implicitly matching all other characters
  NUM_SYMBOL_GROUPS  ///< Total number of symbol groups
};

// Transition table
const std::vector<std::vector<int32_t>> pda_state_tt = {
  /* IN_STATE         {       [       }       ]       "       \    OTHER */
  /* TT_OOS    */ {TT_OOS, TT_OOS, TT_OOS, TT_OOS, TT_STR, TT_OOS, TT_OOS},
  /* TT_STR    */ {TT_STR, TT_STR, TT_STR, TT_STR, TT_OOS, TT_STR, TT_STR},
  /* TT_ESC    */ {TT_STR, TT_STR, TT_STR, TT_STR, TT_STR, TT_STR, TT_STR}};

// Translation table (i.e., for each transition, what are the symbols that we output)
const std::vector<std::vector<std::vector<char>>> pda_out_tt = {
  /* IN_STATE        {      [      }      ]     "  \   OTHER */
  /* TT_OOS    */ {{'{'}, {'['}, {'}'}, {']'}, {'x'}, {'x'}, {'x'}},
  /* TT_STR    */ {{'x'}, {'x'}, {'x'}, {'x'}, {'x'}, {'x'}, {'x'}},
  /* TT_ESC    */ {{'x'}, {'x'}, {'x'}, {'x'}, {'x'}, {'x'}, {'x'}}};

// The i-th string representing all the characters of a symbol group
const std::vector<std::string> pda_sgs = {"{", "[", "}", "]", "\"", "\\"};

// The DFA's starting state
constexpr int32_t start_state = TT_OOS;

}  // namespace

// Base test fixture for tests
struct FstTest : public cudf::test::BaseFixture {
};

TEST_F(FstTest, GroundTruth)
{
  // Type used to represent the atomic symbol type used within the finite-state machine
  using SymbolT = char;

  // Type sufficiently large to index symbols within the input and output (may be unsigned)
  using SymbolOffsetT = uint32_t;

  // Helper class to set up transition table, symbol group lookup table, and translation table
  using DfaFstT = cudf::io::fst::detail::Dfa<char, NUM_SYMBOL_GROUPS, TT_NUM_STATES>;

  // Prepare cuda stream for data transfers & kernels
  rmm::cuda_stream stream{};

  // Test input
  std::string input = R"(  {)"
                      R"(category": "reference",)"
                      R"("index:" [4,12,42],)"
                      R"("author": "Nigel Rees",)"
                      R"("title": "Sayings of the Century",)"
                      R"("price": 8.95)"
                      R"(}  )"
                      R"({)"
                      R"("category": "reference",)"
                      R"("index:" [4,{},null,{"a":[]}],)"
                      R"("author": "Nigel Rees",)"
                      R"("title": "Sayings of the Century",)"
                      R"("price": 8.95)"
                      R"(}  {} [] [ ])";

  // Repeat input sample 1024x
  size_t string_size                 = 1 << 10;
  auto d_input_scalar                = cudf::make_string_scalar(input);
  auto& d_string_scalar              = static_cast<cudf::string_scalar&>(*d_input_scalar);
  const cudf::size_type repeat_times = string_size / input.size();
  auto d_input_string                = cudf::strings::repeat_string(d_string_scalar, repeat_times);
  auto& d_input = static_cast<cudf::scalar_type_t<std::string>&>(*d_input_string);
  input         = d_input.to_string(stream);



  // Prepare input & output buffers
  constexpr std::size_t single_item = 1;
  rmm::device_uvector<SymbolT> d_input(input.size(), stream.view());
  hostdevice_vector<SymbolT> output_gpu(input.size(), stream.view());
  hostdevice_vector<SymbolOffsetT> output_gpu_size(single_item, stream.view());
  hostdevice_vector<SymbolOffsetT> out_indexes_gpu(input.size(), stream.view());
  ASSERT_CUDA_SUCCEEDED(cudaMemcpyAsync(
    d_input.data(), input.data(), input.size() * sizeof(SymbolT), cudaMemcpyHostToDevice, stream.value()));

  // Run algorithm
  DfaFstT parser{pda_sgs, pda_state_tt, pda_out_tt, stream.value()};

  // Allocate device-side temporary storage & run algorithm
  parser.Transduce(d_input.data(),
                   static_cast<SymbolOffsetT>(d_input.size()),
                   output_gpu.device_ptr(),
                   out_indexes_gpu.device_ptr(),
                   output_gpu_size.device_ptr(),
                   start_state,
                   stream.value());

  // Async copy results from device to host
  output_gpu.device_to_host(stream.view());
  out_indexes_gpu.device_to_host(stream.view());
  output_gpu_size.device_to_host(stream.view());

  // Prepare CPU-side results for verification
  std::string output_cpu{};
  std::vector<SymbolOffsetT> out_index_cpu{};
  output_cpu.reserve(input.size());
  out_index_cpu.reserve(input.size());

  // Run CPU-side algorithm
  fst_baseline(std::begin(input),
               std::end(input),
               start_state,
               pda_sgs,
               pda_state_tt,
               pda_out_tt,
               std::back_inserter(output_cpu),
               std::back_inserter(out_index_cpu));

  // Make sure results have been copied back to host
  stream.synchronize();

  // Verify results
  ASSERT_EQ(output_gpu_size[0], output_cpu.size());
  ASSERT_EQ(out_indexes_gpu.size(), out_index_cpu.size());
  for (std::size_t i = 0; i < output_cpu.size(); i++) {
    ASSERT_EQ(output_gpu[i], output_cpu[i]) << "Mismatch at index #" << i;
  }
  for (std::size_t i = 0; i < out_indexes_gpu.size(); i++) {
    ASSERT_EQ(out_indexes_gpu[i], out_index_cpu[i]) << "Mismatch at index #" << i;
  }
}

CUDF_TEST_PROGRAM_MAIN()
