@TestOn('vm')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:test/test.dart';

void main() {
  test('v0.4.1 precision bindings preserve accepted and unsupported paths', () {
    final params = calloc<ggml_init_params>();
    addTearDown(() => calloc.free(params));
    params.ref
      ..mem_size = 1024 * 1024
      ..mem_buffer = ffi.nullptr
      ..no_alloc = true;
    final context = ggml_init(params.ref);
    expect(context, isNot(ffi.nullptr));
    addTearDown(() => ggml_free(context));

    final lhs = ggml_new_tensor_2d(context, ggml_type.GGML_TYPE_F32, 32, 2);
    final rhs = ggml_new_tensor_2d(context, ggml_type.GGML_TYPE_F32, 32, 1);
    final product = ggml_mul_mat(context, lhs, rhs);
    expect(ggml_prec_set_acc(product, ggml_prec.GGML_PREC_F32), isTrue);
    expect(product.ref.op_params[0], ggml_prec.GGML_PREC_F32.value);
    expect(ggml_prec_set_src(product, ggml_prec.GGML_PREC_F16, 1), isTrue);
    expect(product.ref.op_params[3], ggml_prec.GGML_PREC_F16.value);
    expect(ggml_prec_set_src(product, ggml_prec.GGML_PREC_Q8, 0), isFalse);
    expect(product.ref.op_params[3], ggml_prec.GGML_PREC_F16.value);
    expect(ggml_prec_set_acc(lhs, ggml_prec.GGML_PREC_F32), isFalse);
    expect(ggml_prec_set_src(lhs, ggml_prec.GGML_PREC_F16, 1), isFalse);
    expect(ggml_prec.GGML_PREC_DEFAULT, ggml_prec.GGML_PREC_UNDEFINED);
    expect(ggml_prec.fromValue(40), ggml_prec.GGML_PREC_Q4);
  });
}
