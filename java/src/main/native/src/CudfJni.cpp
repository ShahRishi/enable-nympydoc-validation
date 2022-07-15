/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
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

#include <sstream>

#include <cudf/copying.hpp>
#include <cudf/utilities/default_stream.hpp>

#include "cudf_jni_apis.hpp"

namespace {

// handles detaching a thread from the JVM when the thread terminates
class jvm_detach_on_destruct {
public:
  explicit jvm_detach_on_destruct(JavaVM *jvm) : jvm{jvm} {}

  ~jvm_detach_on_destruct() { jvm->DetachCurrentThread(); }

private:
  JavaVM *jvm;
};

} // anonymous namespace

namespace cudf {
namespace jni {

static jclass Host_memory_buffer_jclass;
static jmethodID Host_buffer_allocate;
static jfieldID Host_buffer_address;
static jfieldID Host_buffer_length;

#define HOST_MEMORY_BUFFER_CLASS "ai/rapids/cudf/HostMemoryBuffer"
#define HOST_MEMORY_BUFFER_SIG(param_sig) "(" param_sig ")L" HOST_MEMORY_BUFFER_CLASS ";"

static bool cache_host_memory_buffer_jni(JNIEnv *env) {
  jclass cls = env->FindClass(HOST_MEMORY_BUFFER_CLASS);
  if (cls == nullptr) {
    return false;
  }

  Host_buffer_allocate = env->GetStaticMethodID(cls, "allocate", HOST_MEMORY_BUFFER_SIG("JZ"));
  if (Host_buffer_allocate == nullptr) {
    return false;
  }

  Host_buffer_address = env->GetFieldID(cls, "address", "J");
  if (Host_buffer_address == nullptr) {
    return false;
  }

  Host_buffer_length = env->GetFieldID(cls, "length", "J");
  if (Host_buffer_length == nullptr) {
    return false;
  }

  // Convert local reference to global so it cannot be garbage collected.
  Host_memory_buffer_jclass = static_cast<jclass>(env->NewGlobalRef(cls));
  if (Host_memory_buffer_jclass == nullptr) {
    return false;
  }
  return true;
}

static void release_host_memory_buffer_jni(JNIEnv *env) {
  if (Host_memory_buffer_jclass != nullptr) {
    env->DeleteGlobalRef(Host_memory_buffer_jclass);
    Host_memory_buffer_jclass = nullptr;
  }
}

jobject allocate_host_buffer(JNIEnv *env, jlong amount, jboolean prefer_pinned) {
  jobject ret = env->CallStaticObjectMethod(Host_memory_buffer_jclass, Host_buffer_allocate, amount,
                                            prefer_pinned);

  if (env->ExceptionCheck()) {
    throw std::runtime_error("allocateHostBuffer threw an exception");
  }
  return ret;
}

jlong get_host_buffer_address(JNIEnv *env, jobject buffer) {
  return env->GetLongField(buffer, Host_buffer_address);
}

jlong get_host_buffer_length(JNIEnv *env, jobject buffer) {
  return env->GetLongField(buffer, Host_buffer_length);
}

// Get the JNI environment, attaching the current thread to the JVM if necessary. If the thread
// needs to be attached, the thread will automatically detach when the thread terminates.
JNIEnv *get_jni_env(JavaVM *jvm) {
  JNIEnv *env = nullptr;
  jint rc = jvm->GetEnv(reinterpret_cast<void **>(&env), MINIMUM_JNI_VERSION);
  if (rc == JNI_OK) {
    return env;
  }
  if (rc == JNI_EDETACHED) {
    JavaVMAttachArgs attach_args;
    attach_args.version = MINIMUM_JNI_VERSION;
    attach_args.name = const_cast<char *>("cudf thread");
    attach_args.group = NULL;

    if (jvm->AttachCurrentThreadAsDaemon(reinterpret_cast<void **>(&env), &attach_args) == JNI_OK) {
      // use thread_local object to detach the thread from the JVM when thread terminates.
      thread_local jvm_detach_on_destruct detacher(jvm);
    } else {
      throw std::runtime_error("unable to attach to JVM");
    }

    return env;
  }

  throw std::runtime_error("error detecting thread attach state with JVM");
}

} // namespace jni
} // namespace cudf

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), cudf::jni::MINIMUM_JNI_VERSION) != JNI_OK) {
    return JNI_ERR;
  }

  // cache any class objects and method IDs here
  if (!cudf::jni::cache_contiguous_table_jni(env)) {
    if (!env->ExceptionCheck()) {
      env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                    "Unable to locate contiguous table methods needed by JNI");
    }
    return JNI_ERR;
  }

  if (!cudf::jni::cache_host_memory_buffer_jni(env)) {
    if (!env->ExceptionCheck()) {
      env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                    "Unable to locate host memory buffer methods needed by JNI");
    }
    return JNI_ERR;
  }

  return cudf::jni::MINIMUM_JNI_VERSION;
}

JNIEXPORT void JNI_OnUnload(JavaVM *vm, void *) {
  JNIEnv *env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), cudf::jni::MINIMUM_JNI_VERSION) != JNI_OK) {
    return;
  }

  // release cached class objects here.
  cudf::jni::release_contiguous_table_jni(env);
  cudf::jni::release_host_memory_buffer_jni(env);
}

} // extern "C"
