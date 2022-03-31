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
#pragma once

#include <algorithm>
#include <cstdint>
#include <cub/cub.cuh>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <thrust/fill.h>
#include <thrust/scatter.h>

#include <cudf/types.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf_test/print_utilities.cuh>

#include <rmm/device_uvector.hpp>
#include <rmm/device_buffer.hpp>

namespace cudf {
namespace io {
namespace fst {

/**
 * @brief Describes the kind of stack operation.
 */
enum class stack_op_type : int32_t {
  READ = 0,  ///< Operation reading what is currently on top of the stack
  PUSH = 1,  ///< Operation pushing a new item on top of the stack
  POP  = 2   ///< Operation popping the item currently on top of the stack
};

namespace detail {

/**
 * @brief A convenience struct that represents a stack opepration as a key-value pair, where the key
 * represents the stack's level and the value represents the stack symbol.
 *
 * @tparam KeyT The key type sufficient to cover all stack levels. Must be signed type as any
 * subsequence of stack operations must be able to be covered. E.g., consider the first 10
 * operations are all push and the last 10 operations are all pop operations, we need to be able to
 * represent a partial aggregate of the first ten items, which is '+10', just as well as a partial
 * aggregate of the last ten items, which is '-10'.
 * @tparam ValueT The value type that corresponds to the stack symbols (i.e., covers the stack
 * alphabet).
 */
template <typename KeyT, typename ValueT>
struct KeyValueOp {
  KeyT key;
  ValueT value;
};

/**
 * @brief Helper class to assist with radix sorting KeyValueOp instances by key.
 *
 * @tparam BYTE_SIZE The size of the KeyValueOp.
 */
template <std::size_t BYTE_SIZE>
struct KeyValueOpToUnsigned {
};

template <>
struct KeyValueOpToUnsigned<1U> {
  using UnsignedT = uint8_t;
};

template <>
struct KeyValueOpToUnsigned<2U> {
  using UnsignedT = uint16_t;
};

template <>
struct KeyValueOpToUnsigned<4U> {
  using UnsignedT = uint32_t;
};

template <>
struct KeyValueOpToUnsigned<8U> {
  using UnsignedT = uint64_t;
};

/**
 * @brief Alias template to retrieve an unsigned bit-representation that can be used for radix
 * sorting the key of a KeyValueOp.
 *
 * @tparam KeyValueOpT The KeyValueOp class template instance for which to get an unsigned
 * bit-representation
 */
template <typename KeyValueOpT>
using UnsignedKeyValueOpType = typename KeyValueOpToUnsigned<sizeof(KeyValueOpT)>::UnsignedT;

/**
 * @brief Function object class template used for converting a stack operation to a key-value store
 * operation, where the key corresponds to the stack level being accessed.
 *
 * @tparam KeyValueOpT
 * @tparam StackSymbolToStackOpTypeT
 */
template <typename KeyValueOpT, typename StackSymbolToStackOpTypeT>
struct StackSymbolToKVOp {
  template <typename StackSymbolT>
  constexpr CUDF_HOST_DEVICE KeyValueOpT operator()(StackSymbolT const& stack_symbol) const
  {
    stack_op_type stack_op = symbol_to_stack_op_type(stack_symbol);
    // PUSH => +1, POP => -1, READ => 0
    int32_t level_delta = stack_op == stack_op_type::PUSH  ? 1
                          : stack_op == stack_op_type::POP ? -1
                                                           : 0;
    return KeyValueOpT{static_cast<decltype(KeyValueOpT::key)>(level_delta), stack_symbol};
  }

  /// Function object returning a stack operation type for a given stack symbol
  StackSymbolToStackOpTypeT symbol_to_stack_op_type;
};

/**
 * @brief Binary reduction operator to compute the absolute stack level from relative stack levels
 * (i.e., +1 for a PUSH, -1 for a POP operation).
 */
struct AddStackLevelFromKVOp {
  template <typename KeyT, typename ValueT>
  constexpr CUDF_HOST_DEVICE KeyValueOp<KeyT, ValueT> operator()(
    KeyValueOp<KeyT, ValueT> const& lhs, KeyValueOp<KeyT, ValueT> const& rhs) const
  {
    KeyT new_level = lhs.key + rhs.key;
    return KeyValueOp<KeyT, ValueT>{new_level, rhs.value};
  }
};

/**
 * @brief Binary reduction operator that propagates a write operation for a specific key to all
 * reads of that same key. That is, if the key of LHS compares equal to the key of the RHS and if
 * the RHS is a read and the LHS is a write operation type, then we return LHS, otherwise we return
 * the RHS.
 */
template <typename StackSymbolToStackOpTypeT>
struct PopulatePopWithPush {
  template <typename KeyT, typename ValueT>
  constexpr CUDF_HOST_DEVICE KeyValueOp<KeyT, ValueT> operator()(
    KeyValueOp<KeyT, ValueT> const& lhs, KeyValueOp<KeyT, ValueT> const& rhs) const
  {
    // If RHS is a read, then we need to figure out whether we can propagate the value from the LHS
    bool is_rhs_read = symbol_to_stack_op_type(rhs.value) != stack_op_type::PUSH;

    // Whether LHS is a matching write (i.e., the push operation that is on top of the stack for the
    // RHS's read)
    bool is_lhs_matching_write =
      (lhs.key == rhs.key) && symbol_to_stack_op_type(lhs.value) == stack_op_type::PUSH;

    return (is_rhs_read && is_lhs_matching_write) ? lhs : rhs;
  }

  /// Function object returning a stack operation type for a given stack symbol
  StackSymbolToStackOpTypeT symbol_to_stack_op_type;
};

/**
 * @brief Binary reduction operator that is used to replace each read_symbol occurance with the last
 * non-read_symbol that precedes such read_symbol.
 */
template <typename StackSymbolT>
struct PropagateLastWrite {
  constexpr CUDF_HOST_DEVICE StackSymbolT operator()(StackSymbolT const& lhs,
                                                     StackSymbolT const& rhs) const
  {
    // If RHS is a yet-to-be-propagated, then we need to check whether we can use the LHS to fill
    bool is_rhs_read = (rhs == read_symbol);

    // We propagate the write from the LHS if it's a write
    bool is_lhs_write = (lhs != read_symbol);

    return (is_rhs_read && is_lhs_write) ? lhs : rhs;
  }

  /// The read_symbol that is supposed to be replaced
  StackSymbolT read_symbol;
};

/**
 * @brief Helper function object class to convert a KeyValueOp to the stack symbol of that
 * KeyValueOp.
 */
struct KVOpToStackSymbol {
  template <typename KeyT, typename ValueT>
  constexpr CUDF_HOST_DEVICE ValueT operator()(KeyValueOp<KeyT, ValueT> const& kv_op) const
  {
    return kv_op.value;
  }
};

/**
 * @brief Replaces all operations that apply to stack level '0' with the empty stack symbol
 */
template <typename KeyValueOpT>
struct RemapEmptyStack {
  constexpr CUDF_HOST_DEVICE KeyValueOpT operator()(KeyValueOpT const& kv_op) const
  {
    return kv_op.key == 0 ? empty_stack_symbol : kv_op;
  }
  KeyValueOpT empty_stack_symbol;
};

/**
 * @brief Function object to return only the key part from a KeyValueOp instance.
 */
struct KVOpToKey {
  template <typename KeyT, typename ValueT>
  constexpr CUDF_HOST_DEVICE KeyT operator()(KeyValueOp<KeyT, ValueT> const& kv_op) const
  {
    return kv_op.key;
  }
};

/**
 * @brief Function object to return only the value part from a KeyValueOp instance.
 */
struct KVOpToValue {
  template <typename KeyT, typename ValueT>
  constexpr CUDF_HOST_DEVICE ValueT operator()(KeyValueOp<KeyT, ValueT> const& kv_op) const
  {
    return kv_op.value;
  }
};

/**
 * @brief Retrieves an iterator that returns only the `key` part from a KeyValueOp iterator.
 */
template <typename KeyValueOpItT>
auto get_key_it(KeyValueOpItT it)
{
  return thrust::make_transform_iterator(it, KVOpToKey{});
}

/**
 * @brief Retrieves an iterator that returns only the `value` part from a KeyValueOp iterator.
 */
template <typename KeyValueOpItT>
auto get_value_it(KeyValueOpItT it)
{
  return thrust::make_transform_iterator(it, KVOpToValue{});
}

}  // namespace detail

/**
 * @brief Takes a sparse representation of a sequence of stack operations that either push something
 * onto the stack or pop something from the stack and resolves the symbol that is on top of the
 * stack.
 *
 * @tparam StackLevelT Signed integer type that must be sufficient to cover [-max_stack_level,
 * max_stack_level] for the given sequence of stack operations. Must be signed as it needs to cover
 * the stack level of any arbitrary subsequence of stack operations.
 * @tparam StackSymbolItT An input iterator type that provides the sequence of symbols that
 * represent stack operations
 * @tparam SymbolPositionT The index that this stack operation is supposed to apply to
 * @tparam StackSymbolToStackOpT Function object class to transform items from StackSymbolItT to
 * stack_op_type
 * @tparam TopOfStackOutItT Output iterator type to which StackSymbolT are being assigned
 * @tparam StackSymbolT The internal type being used (usually corresponding to StackSymbolItT's
 * value_type)
 * @tparam OffsetT Signed or unsigned integer type large enough to index into both the sparse input
 * sequence and the top-of-stack output sequence
 * @param[in] d_symbols Sequence of symbols that represent stack operations. Memory may alias with
 * \p d_top_of_stack
 * @param[in,out] d_symbol_positions Sequence of symbol positions (for a sparse representation),
 * sequence must be ordered in ascending order. Note, the memory of this array is repurposed for
 * double-buffering.
 * @param[in] symbol_to_stack_op Function object that returns a stack operation type (push, pop, or
 * read) for a given symbol from \p d_symbols
 * @param[out] d_top_of_stack A random access output iterator that will be populated with
 * what-is-on-top-of-the-stack for the given sequence of stack operations \p d_symbols
 * @param[in] empty_stack_symbol The symbol that will be written to top_of_stack whenever the stack
 * was empty
 * @param[in] read_symbol A symbol that may not be confused for a symbol that would push to the
 * stack
 * @param[in] num_symbols_in The number of symbols in the sparse representation
 * @param[in] num_symbols_out The number of symbols that are supposed to be filled with
 * what-is-on-top-of-the-stack
 * @param[in] stream The cuda stream to which to dispatch the work
 */
template <typename StackLevelT,
          typename StackSymbolItT,
          typename SymbolPositionT,
          typename StackSymbolToStackOpT,
          typename TopOfStackOutItT,
          typename StackSymbolT,
          typename OffsetT>
void SparseStackOpToTopOfStack(rmm::device_buffer& temp_storage,
                               StackSymbolItT d_symbols,
                               SymbolPositionT* d_symbol_positions,
                               StackSymbolToStackOpT symbol_to_stack_op,
                               TopOfStackOutItT d_top_of_stack,
                               StackSymbolT empty_stack_symbol,
                               StackSymbolT read_symbol,
                               OffsetT num_symbols_in,
                               OffsetT num_symbols_out,
                               cudaStream_t stream = nullptr)
{
  // Type used to hold key-value pairs (key being the stack level and the value being the stack
  // symbol)
  using KeyValueOpT = detail::KeyValueOp<StackLevelT, StackSymbolT>;

  // The unsigned integer type that we use for radix sorting items of type KeyValueOpT
  using KVOpUnsignedT = detail::UnsignedKeyValueOpType<KeyValueOpT>;

  // Transforming sequence of stack symbols to key-value store operations, where the key corresponds
  // to the stack level of a given stack operation and the value corresponds to the stack symbol of
  // that operation
  using StackSymbolToKVOpT = detail::StackSymbolToKVOp<KeyValueOpT, StackSymbolToStackOpT>;

  // TransformInputIterator converting stack symbols to key-value store operations
  using TransformInputItT =
    cub::TransformInputIterator<KeyValueOpT, StackSymbolToKVOpT, StackSymbolItT>;

  // Converting a stack symbol that may either push or pop to a key-value store operation:
  // stack_symbol -> ([+1,0,-1], stack_symbol)
  StackSymbolToKVOpT stack_sym_to_kv_op{symbol_to_stack_op};
  TransformInputItT stack_symbols_in(d_symbols, stack_sym_to_kv_op);

  // Double-buffer for sorting along the given sequence of symbol positions (the sparse
  // representation)
  cub::DoubleBuffer<SymbolPositionT> d_symbol_positions_db{nullptr, nullptr};

  // Double-buffer for sorting the key-value store operations
  cub::DoubleBuffer<KeyValueOpT> d_kv_operations{nullptr, nullptr};

  // A double-buffer that aliases memory from d_kv_operations with unsigned types in order to
  // be able to perform a radix sort
  cub::DoubleBuffer<KVOpUnsignedT> d_kv_operations_unsigned{nullptr, nullptr};

  constexpr std::size_t bits_per_byte = 8;
  constexpr std::size_t begin_bit     = offsetof(KeyValueOpT, key) * bits_per_byte;
  constexpr std::size_t end_bit       = begin_bit + (sizeof(KeyValueOpT::key) * bits_per_byte);

  // The key-value store operation that makes sure that reads for stack level '0' will be populated
  // with the empty_stack_symbol
  KeyValueOpT const empty_stack{0, empty_stack_symbol};

  cub::TransformInputIterator<KeyValueOpT, detail::RemapEmptyStack<KeyValueOpT>, KeyValueOpT*>
    kv_ops_scan_in(nullptr, detail::RemapEmptyStack<KeyValueOpT>{empty_stack});
  KeyValueOpT* kv_ops_scan_out = nullptr;

  std::size_t stack_level_scan_bytes      = 0;
  std::size_t stack_level_sort_bytes      = 0;
  std::size_t match_level_scan_bytes      = 0;
  std::size_t propagate_writes_scan_bytes = 0;

  // Getting temporary storage requirements for the prefix sum of the stack level after each
  // operation
  CUDA_TRY(cub::DeviceScan::InclusiveScan(nullptr,
                                          stack_level_scan_bytes,
                                          stack_symbols_in,
                                          d_kv_operations.Current(),
                                          detail::AddStackLevelFromKVOp{},
                                          num_symbols_in,
                                          stream));

  // Getting temporary storage requirements for the stable radix sort (sorting by stack level of the
  // operations)
  CUDA_TRY(cub::DeviceRadixSort::SortPairs(nullptr,
                                           stack_level_sort_bytes,
                                           d_kv_operations_unsigned,
                                           d_symbol_positions_db,
                                           num_symbols_in,
                                           begin_bit,
                                           end_bit,
                                           stream));

  // Getting temporary storage requirements for the scan to match pop operations with the latest
  // push of the same level
  CUDA_TRY(cub::DeviceScan::InclusiveScan(
    nullptr,
    match_level_scan_bytes,
    kv_ops_scan_in,
    kv_ops_scan_out,
    detail::PopulatePopWithPush<StackSymbolToStackOpT>{symbol_to_stack_op},
    num_symbols_in,
    stream));

  // Getting temporary storage requirements for the scan to propagate top-of-stack for spots that
  // didn't push or pop
  CUDA_TRY(cub::DeviceScan::ExclusiveScan(nullptr,
                                          propagate_writes_scan_bytes,
                                          d_top_of_stack,
                                          d_top_of_stack,
                                          detail::PropagateLastWrite<StackSymbolT>{read_symbol},
                                          empty_stack_symbol,
                                          num_symbols_out,
                                          stream));

  // Scratch memory required by the algorithms
  auto total_temp_storage_bytes = std::max({stack_level_scan_bytes,
                                                  stack_level_sort_bytes,
                                                  match_level_scan_bytes,
                                                  propagate_writes_scan_bytes});

  if (temp_storage.size() < total_temp_storage_bytes) {
    temp_storage.resize(total_temp_storage_bytes, stream);
  }
  // Actual device buffer size, as we need to pass in an lvalue-ref to cub algorithms as temp_storage_bytes
  total_temp_storage_bytes = temp_storage.size();

  rmm::device_uvector<SymbolPositionT> d_symbol_position_alt{num_symbols_in, stream};
  rmm::device_uvector<KeyValueOpT> d_kv_ops_current{num_symbols_in, stream};
  rmm::device_uvector<KeyValueOpT> d_kv_ops_alt{num_symbols_in, stream};

  //------------------------------------------------------------------------------
  // ALGORITHM
  //------------------------------------------------------------------------------
  // Initialize double-buffer for sorting the indexes of the sequence of sparse stack operations
  d_symbol_positions_db =
    cub::DoubleBuffer<SymbolPositionT>{d_symbol_positions, d_symbol_position_alt.data()};

  // Initialize double-buffer for sorting the indexes of the sequence of sparse stack operations
  d_kv_operations = cub::DoubleBuffer<KeyValueOpT>{d_kv_ops_current.data(), d_kv_ops_alt.data()};

  // Compute prefix sum of the stack level after each operation
  CUDA_TRY(cub::DeviceScan::InclusiveScan(temp_storage.data(),
                                          total_temp_storage_bytes,
                                          stack_symbols_in,
                                          d_kv_operations.Current(),
                                          detail::AddStackLevelFromKVOp{},
                                          num_symbols_in,
                                          stream));

  // Dump info on stack operations: (stack level change + symbol) -> (absolute stack level + symbol)
  test::print::print_array(num_symbols_in,
                           stream,
                           get_key_it(stack_symbols_in),
                           get_value_it(stack_symbols_in),
                           get_key_it(d_kv_operations.Current()),
                           get_value_it(d_kv_operations.Current()));

  // Stable radix sort, sorting by stack level of the operations
  d_kv_operations_unsigned =
    cub::DoubleBuffer<KVOpUnsignedT>{reinterpret_cast<KVOpUnsignedT*>(d_kv_operations.Current()),
                                     reinterpret_cast<KVOpUnsignedT*>(d_kv_operations.Alternate())};
  CUDA_TRY(cub::DeviceRadixSort::SortPairs(temp_storage.data(),
                                           total_temp_storage_bytes,
                                           d_kv_operations_unsigned,
                                           d_symbol_positions_db,
                                           num_symbols_in,
                                           begin_bit,
                                           end_bit,
                                           stream));

  // TransformInputIterator that remaps all operations on stack level 0 to the empty stack symbol
  kv_ops_scan_in  = {reinterpret_cast<KeyValueOpT*>(d_kv_operations_unsigned.Current()),
                    detail::RemapEmptyStack<KeyValueOpT>{empty_stack}};
  kv_ops_scan_out = reinterpret_cast<KeyValueOpT*>(d_kv_operations_unsigned.Alternate());

  // Dump info on stack operations sorted by their stack level (i.e. stack level after applying
  // operation)
  test::print::print_array(
    num_symbols_in, stream, get_key_it(kv_ops_scan_in), get_value_it(kv_ops_scan_in));

  // Exclusive scan to match pop operations with the latest push operation of that level
  CUDA_TRY(cub::DeviceScan::InclusiveScan(
    temp_storage.data(),
    total_temp_storage_bytes,
    kv_ops_scan_in,
    kv_ops_scan_out,
    detail::PopulatePopWithPush<StackSymbolToStackOpT>{symbol_to_stack_op},
    num_symbols_in,
    stream));

  // Dump info on stack operations sorted by their stack level (i.e. stack level after applying
  // operation)
  test::print::print_array(num_symbols_in,
                           stream,
                           get_key_it(kv_ops_scan_in),
                           get_value_it(kv_ops_scan_in),
                           get_key_it(kv_ops_scan_out),
                           get_value_it(kv_ops_scan_out));

  // Fill the output tape with read-symbol
  thrust::fill(thrust::cuda::par.on(stream),
               thrust::device_ptr<StackSymbolT>{d_top_of_stack},
               thrust::device_ptr<StackSymbolT>{d_top_of_stack + num_symbols_out},
               read_symbol);

  // Transform the key-value operations to the stack symbol they represent
  cub::TransformInputIterator<StackSymbolT, detail::KVOpToStackSymbol, KeyValueOpT*>
    kv_op_to_stack_sym_it(kv_ops_scan_out, detail::KVOpToStackSymbol{});

  // Scatter the stack symbols to the output tape (spots that are not scattered to have been
  // pre-filled with the read-symbol)
  thrust::scatter(thrust::cuda::par.on(stream),
                  kv_op_to_stack_sym_it,
                  kv_op_to_stack_sym_it + num_symbols_in,
                  d_symbol_positions_db.Current(),
                  d_top_of_stack);

  // Dump the output tape that has many yet-to-be-filled spots (i.e., all spots that were not given
  // in the sparse representation)
  test::print::print_array(
    std::min(num_symbols_in, static_cast<decltype(num_symbols_in)>(10000)), stream, d_top_of_stack);

  // We perform an exclusive scan in order to fill the items at the very left that may
  // be reading the empty stack before there's the first push occurance in the sequence.
  // Also, we're interested in the top-of-the-stack symbol before the operation was applied.
  CUDA_TRY(cub::DeviceScan::ExclusiveScan(temp_storage.data(),
                                          total_temp_storage_bytes,
                                          d_top_of_stack,
                                          d_top_of_stack,
                                          detail::PropagateLastWrite<StackSymbolT>{read_symbol},
                                          empty_stack_symbol,
                                          num_symbols_out,
                                          stream));

  // Dump the final output
  test::print::print_array(
    std::min(num_symbols_in, static_cast<decltype(num_symbols_in)>(10000)), stream, d_top_of_stack);
}

}  // namespace fst
}  // namespace io
}  // namespace cudf
