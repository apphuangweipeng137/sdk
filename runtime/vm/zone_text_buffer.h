// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_ZONE_TEXT_BUFFER_H_
#define RUNTIME_VM_ZONE_TEXT_BUFFER_H_

#include "vm/allocation.h"
#include "vm/globals.h"

namespace dart {

class Zone;

// TextBuffer maintains a dynamic character buffer with a printf-style way to
// append text.
class ZoneTextBuffer : ValueObject {
 public:
  ZoneTextBuffer(Zone* zone, intptr_t initial_capacity);
  ~ZoneTextBuffer() {}

  intptr_t Printf(const char* format, ...) PRINTF_ATTRIBUTE(2, 3);
  void AddString(const char* s);

  char* buffer() { return buffer_; }
  intptr_t length() { return length_; }

 private:
  void EnsureCapacity(intptr_t len);
  Zone* zone_;
  char* buffer_;
  intptr_t length_;
  intptr_t capacity_;
};

}  // namespace dart

#endif  // RUNTIME_VM_ZONE_TEXT_BUFFER_H_
