"""Check generated callback allocation policy and Apple arm64 ABI."""
import argparse
from pathlib import Path
import runpy
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--node-source', type=Path, required=True)
parser.add_argument('--check-built', action='store_true')
args = parser.parse_args()
generator = runpy.run_path(str(args.node_source / 'deps/libffi/generate-headers.py'))
for os_name, trampoline, long_double in [('ios', True, '0'), ('mac', True, '0'), ('linux', False, '1')]:
    assert generator['uses_exec_trampoline_table'](os_name, 'arm64') is trampoline
    assert generator['has_long_double'](os_name, 'arm64') == long_double
    with tempfile.TemporaryDirectory() as temp:
        generator['generate_headers'](temp, 'arm64', os_name)
        config = (Path(temp) / 'fficonfig.h').read_text()
        header = (Path(temp) / 'ffi.h').read_text()
        assert ('#define FFI_EXEC_TRAMPOLINE_TABLE 1' in config) is trampoline
        assert f'#if {int(trampoline)}\n  void *trampoline_table;' in header
if args.check_built:
    configs = list((args.node_source / 'out/Release').rglob('libffi/fficonfig.h'))
    assert configs, 'built libffi config missing'
    for config in configs:
        assert '#define FFI_EXEC_TRAMPOLINE_TABLE 1' in config.read_text(), config
        print(f'BUILT_CALLBACK_TRAMPOLINE_TABLE=1 {config}')
print('LIBFFI_IOS_CALLBACK_HEADERS_PASS')
