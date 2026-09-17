@TestOn('vm')
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:test/test.dart';

void main() {
  test('v0.4.1 precision bindings preserve accepted and unsupported paths', () {
    // Windows does not re-export dependency DLL symbols through llamadart.
    // Resolve ggml operations from the same emitted asset used by the service.
    final ggml = Platform.isWindows
        ? ffi.DynamicLibrary.open('package:llamadart/ggml-base')
        : null;
    final init = ggml == null
        ? ggml_init
        : ggml.lookupFunction<
            ffi.Pointer<ggml_context> Function(ggml_init_params),
            ffi.Pointer<ggml_context> Function(ggml_init_params)
          >('ggml_init');
    final free = ggml == null
        ? ggml_free
        : ggml.lookupFunction<
            ffi.Void Function(ffi.Pointer<ggml_context>),
            void Function(ffi.Pointer<ggml_context>)
          >('ggml_free');
    final newTensor = ggml == null
        ? (ffi.Pointer<ggml_context> ctx, int type, int x, int y) =>
              ggml_new_tensor_2d(ctx, ggml_type.fromValue(type), x, y)
        : ggml.lookupFunction<
            ffi.Pointer<ggml_tensor> Function(
              ffi.Pointer<ggml_context>,
              ffi.UnsignedInt,
              ffi.Int64,
              ffi.Int64,
            ),
            ffi.Pointer<ggml_tensor> Function(
              ffi.Pointer<ggml_context>,
              int,
              int,
              int,
            )
          >('ggml_new_tensor_2d');
    final multiply = ggml == null
        ? ggml_mul_mat
        : ggml.lookupFunction<
            ffi.Pointer<ggml_tensor> Function(
              ffi.Pointer<ggml_context>,
              ffi.Pointer<ggml_tensor>,
              ffi.Pointer<ggml_tensor>,
            ),
            ffi.Pointer<ggml_tensor> Function(
              ffi.Pointer<ggml_context>,
              ffi.Pointer<ggml_tensor>,
              ffi.Pointer<ggml_tensor>,
            )
          >('ggml_mul_mat');
    final setAccumulator = ggml == null
        ? (ffi.Pointer<ggml_tensor> tensor, int precision) =>
              ggml_prec_set_acc(tensor, ggml_prec.fromValue(precision))
        : ggml.lookupFunction<
            ffi.Bool Function(ffi.Pointer<ggml_tensor>, ffi.UnsignedInt),
            bool Function(ffi.Pointer<ggml_tensor>, int)
          >('ggml_prec_set_acc');
    final setSource = ggml == null
        ? (ffi.Pointer<ggml_tensor> tensor, int precision, int index) =>
              ggml_prec_set_src(tensor, ggml_prec.fromValue(precision), index)
        : ggml.lookupFunction<
            ffi.Bool Function(
              ffi.Pointer<ggml_tensor>,
              ffi.UnsignedInt,
              ffi.Int,
            ),
            bool Function(ffi.Pointer<ggml_tensor>, int, int)
          >('ggml_prec_set_src');
    final params = calloc<ggml_init_params>();
    addTearDown(() => calloc.free(params));
    params.ref
      ..mem_size = 1024 * 1024
      ..mem_buffer = ffi.nullptr
      ..no_alloc = true;
    final context = init(params.ref);
    expect(context, isNot(ffi.nullptr));
    addTearDown(() => free(context));

    final lhs = newTensor(context, ggml_type.GGML_TYPE_F32.value, 32, 2);
    final rhs = newTensor(context, ggml_type.GGML_TYPE_F32.value, 32, 1);
    final product = multiply(context, lhs, rhs);
    expect(setAccumulator(product, ggml_prec.GGML_PREC_F32.value), isTrue);
    expect(product.ref.op_params[0], ggml_prec.GGML_PREC_F32.value);
    expect(setSource(product, ggml_prec.GGML_PREC_F16.value, 1), isTrue);
    expect(product.ref.op_params[3], ggml_prec.GGML_PREC_F16.value);
    expect(setSource(product, ggml_prec.GGML_PREC_Q8.value, 0), isFalse);
    expect(product.ref.op_params[3], ggml_prec.GGML_PREC_F16.value);
    expect(setAccumulator(lhs, ggml_prec.GGML_PREC_F32.value), isFalse);
    expect(setSource(lhs, ggml_prec.GGML_PREC_F16.value, 1), isFalse);
    expect(ggml_prec.GGML_PREC_DEFAULT, ggml_prec.GGML_PREC_UNDEFINED);
    expect(ggml_prec.fromValue(40), ggml_prec.GGML_PREC_Q4);
  });
}
