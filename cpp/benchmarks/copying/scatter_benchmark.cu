/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#include <benchmark/benchmark.h>

#include <cudf/copying.hpp>

#include <tests/utilities/cudf_gtest.hpp>
#include <tests/utilities/base_fixture.hpp>
// #include <tests/utilities/type_lists.hpp>
#include <tests/utilities/column_wrapper.hpp>
#include <tests/utilities/column_utilities.hpp>
#include <tests/utilities/table_utilities.hpp>

#include <cudf/types.hpp>
#include <cudf/utilities/legacy/wrapper_types.hpp>

#include <random>
#include <algorithm>

#include "../fixture/benchmark_fixture.hpp"
#include "../synchronization/synchronization.hpp"

class Scatter: public cudf::benchmark {
};

template<class TypeParam, bool coalesce>
void BM_scatter(benchmark::State& state){
  const cudf::size_type source_size{(cudf::size_type)state.range(0)};
  const cudf::size_type n_cols = (cudf::size_type)state.range(1);

  // Every element is valid
  auto data = cudf::test::make_counting_transform_iterator(0, [](auto i){return i;});

  // Gather indices
  std::vector<cudf::size_type> host_map_data(source_size);
  std::iota(host_map_data.begin(), host_map_data.end(), 0);

  if(coalesce){
    std::reverse(host_map_data.begin(), host_map_data.end());
  }else{
    std::random_shuffle(host_map_data.begin(), host_map_data.end());
  }
   
  cudf::test::fixed_width_column_wrapper<cudf::size_type> scatter_map{
    host_map_data.begin(), host_map_data.end()};
 
  std::vector<cudf::test::fixed_width_column_wrapper<TypeParam>> source_column_wrappers;
  std::vector<cudf::column_view> source_columns;
  
  std::vector<cudf::test::fixed_width_column_wrapper<TypeParam>> target_column_wrappers;
  std::vector<cudf::column_view> target_columns;

  for (int i=0; i<n_cols; ++i) {
    source_column_wrappers.push_back(cudf::test::fixed_width_column_wrapper
             <TypeParam>(data, data+source_size));
    source_columns.push_back(source_column_wrappers[i]);
  }
  
  for (int i=0; i<n_cols; ++i) {
    target_column_wrappers.push_back(cudf::test::fixed_width_column_wrapper
             <TypeParam>(data, data+source_size));
    target_columns.push_back(target_column_wrappers[i]);
  }

  cudf::table_view source_table {source_columns};
  cudf::table_view target_table {target_columns};

  for(auto _ : state){
    cuda_event_timer raii(state, true); // flush_l2_cache = true, stream = 0
    std::unique_ptr<cudf::experimental::table> result =
      std::move(cudf::experimental::scatter(source_table, scatter_map, target_table));
  }
  
  state.SetBytesProcessed(
      static_cast<int64_t>(state.iterations())*state.range(0)*n_cols*2*sizeof(TypeParam));
}

#define SBM_BENCHMARK_DEFINE(name, type, coalesce)                      \
BENCHMARK_DEFINE_F(Scatter, name)(::benchmark::State& state) {        \
  BM_scatter<type, coalesce>(state);                                    \
}                                                                       \
BENCHMARK_REGISTER_F(Scatter, name)->RangeMultiplier(2)->Ranges({{1<<10,1<<25},{1,8}})->UseManualTime();

SBM_BENCHMARK_DEFINE(double_coalesce_x,double, true);
SBM_BENCHMARK_DEFINE(double_coalesce_o,double,false);
