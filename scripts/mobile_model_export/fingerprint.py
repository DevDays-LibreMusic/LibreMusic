"""Compact ONNX diagnostics: hashes only, never weight values or model copies."""
import hashlib
import json
from pathlib import Path


def fingerprint(path):
    import onnx
    model = onnx.load(str(path), load_external_data=False)
    tensors = {}

    def measure(key, tensor):
        tensors[key] = {
            'sha256': hashlib.sha256(tensor.SerializeToString()).hexdigest(),
            'dims': list(tensor.dims), 'dtype': tensor.data_type,
        }
        # Keep tensor identity/type/shape in the structural fingerprint.
        for field in ('raw_data', 'float_data', 'int32_data', 'string_data',
                      'int64_data', 'double_data', 'uint64_data'):
            tensor.ClearField(field)

    for tensor in model.graph.initializer:
        measure('initializer/' + tensor.name, tensor)
    for index, node in enumerate(model.graph.node):
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.TENSOR:
                measure(f'node/{index}/{node.name}/{attribute.name}', attribute.t)
    return {
        'structure_sha256': hashlib.sha256(model.SerializeToString()).hexdigest(),
        'tensors': tensors,
    }


def diagnose(path, reference):
    expected = json.loads(Path(reference).read_text())
    actual = fingerprint(path)
    different = []
    for key in sorted(expected['tensors'].keys() | actual['tensors'].keys()):
        if expected['tensors'].get(key) != actual['tensors'].get(key):
            different.append({'tensor': key, 'expected': expected['tensors'].get(key),
                              'actual': actual['tensors'].get(key)})
    print(json.dumps({'model_diagnostic': str(path),
                      'structure_matches_reference': actual['structure_sha256'] == expected['structure_sha256'],
                      'reference_structure_sha256': expected['structure_sha256'],
                      'actual_structure_sha256': actual['structure_sha256'],
                      'changed_tensor_count': len(different),
                      'changed_tensors': different[:100]}, indent=2), flush=True)
