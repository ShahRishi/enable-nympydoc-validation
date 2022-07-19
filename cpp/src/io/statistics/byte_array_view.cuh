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

#include <cudf/utilities/span.hpp>

namespace cudf::io {

class byte_array_view {
 public:
  using element_type = int8_t const;  ///< The type of the elements in the byte array

  constexpr byte_array_view() noexcept {}
  /**
   * @brief Constructs a byte_array_view from a pointer and a size.
   *
   * @param data Pointer to the first element in the byte array.
   * @param size The number of elements in the byte array.
   */
  constexpr byte_array_view(element_type* data, std::size_t size) : _data(data, size) {}
  constexpr byte_array_view(byte_array_view const&) noexcept = default;  ///< Copy constructor
  /**
   * @brief Copy assignment operator.
   *
   * @return Reference to this byte_array_view.
   */
  constexpr byte_array_view& operator=(byte_array_view const&) noexcept = default;

  /**
   * @brief Returns a reference to the idx-th element of the byte_array_view.
   *
   * The behavior is undefined if idx is out of range (i.e., if it is greater than or equal to
   * size()).
   *
   * @param idx The index of the element to access.
   * @return A reference to the idx-th element of the byte_array_view, i.e., `_data.data()[idx]`.
   */
  constexpr element_type& operator[](std::size_t idx) const { return _data[idx]; }

  /**
   * @brief Returns a pointer to the beginning of the byte_array_view.
   *
   * @return A pointer to the first element of the byte_array_view.
   */
  constexpr element_type* data() const noexcept { return _data.data(); }

  /**
   * @brief Returns the number of elements in the byte_array_view.
   *
   * @return The number of elements in the byte_array_view.
   */
  [[nodiscard]] constexpr std::size_t size() const noexcept { return _data.size(); }

  /**
   * @brief Returns the size of the byte_array_view in bytes.
   *
   * @return The size of the byte_array_view in bytes
   */
  [[nodiscard]] constexpr std::size_t size_bytes() const noexcept { return _data.size_bytes(); }

  /**
   * @brief Comparing target byte_array_view with this byte_array_view. Each byte in the array is
   * compared.
   *
   * @param byte_array_view Target byte_array_view to compare with this byte_array_view.
   * @return 0  If they compare equal.
   *         <0 Either the value of the first byte of this byte_array_view that does not match is
   * lower in the arg byte_array_view, or all compared bytes match but the arg byte_array_view is
   * shorter. >0 Either the value of the first byte of this byte_array_view that does not match is
   * greater in the arg byte_array_view, or all compared bytes match but the arg byte_array_view is
   * longer.
   */
  __device__ inline int32_t compare(byte_array_view const& rhs) const
  {
    auto const len1  = size_bytes();
    auto const len2  = rhs.size_bytes();
    auto const* ptr1 = this->data();
    auto const* ptr2 = rhs.data();
    if ((ptr1 == ptr2) && (len1 == len2)) { return 0; }
    std::size_t idx = 0;
    for (; (idx < len1) && (idx < len2); ++idx) {
      if (ptr1[idx] != ptr2[idx]) {
        return static_cast<int32_t>(ptr1[idx]) - static_cast<int32_t>(ptr2[idx]);
      }
    }
    if (idx < len1) return 1;
    if (idx < len2) return -1;
    return 0;
  }

  /**
   * @brief Returns true if this string is ordered before rhs.
   *
   * @param rhs Target string to compare with this string.
   * @return true if this string is ordered before rhs
   */
  [[nodiscard]] __device__ inline bool operator<(const byte_array_view& rhs) const
  {
    return compare(rhs) < 0;
  }
  /**
   * @brief Returns true if rhs is ordered before this string.
   *
   * @param rhs Target string to compare with this string.
   * @return true if rhs is ordered before this string
   */
  [[nodiscard]] __device__ inline bool operator>(const byte_array_view& rhs) const
  {
    return compare(rhs) > 0;
  }

 private:
  device_span<element_type> _data{};
};

}  // namespace cudf::io
