"""Run the same behavioral probes against the original baseline and FINAL on macOS.

基线提交只存在于上游仓库历史里；本仓库是重新初始化的，历史里没有那个 commit。
所以基线那一半做成可选：`git cat-file -e` 探到才跑，探不到就只跑 FINAL 的绿色断言，
并在输出里说明"红色基线未参与"。用 BASELINE_COMMIT 环境变量可以指定任意可用提交。
"""
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

root = Path.cwd()
workflow = (root / '.github/workflows/build-ios.yml').read_text()
block = workflow.split('- name: Capture activity contract')[1].split('- name:')[0]
sources = re.findall(r'\s+([\w/.-]+\.swift)\s+\\', block)
sources = [p for p in sources if not p.startswith('tools/')]
probe = root / 'tools/FinalRegressionCheck/main.swift'
baseline = os.environ.get('BASELINE_COMMIT', 'c86503472165a24d24a41e297febca481bb6c14b')


def baseline_available(commit):
    try:
        return subprocess.run(['git', 'cat-file', '-e', commit + '^{commit}'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except Exception:
        return False


have_baseline = baseline_available(baseline)
if not have_baseline:
    print(f'note: 基线提交 {baseline[:12]} 不在本仓库历史里，跳过红色基线，只验 FINAL', flush=True)

with tempfile.TemporaryDirectory(prefix='final-regression-') as tmp:
    tmp = Path(tmp)
    targets = []
    if have_baseline:
        old = tmp / 'baseline'
        old.mkdir()
        archive = subprocess.check_output(['git', 'archive', baseline])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(old, filter='data')
        targets.append(('baseline', old))
    targets.append(('final', root))

    for label, folder in targets:
        exe = tmp / label
        if label == 'baseline':
            exe = tmp / 'baseline-probe'
        subprocess.run(['swiftc', '-swift-version', '5', *[str(folder / p) for p in sources],
                        str(probe), '-o', str(exe)], check=True)
        result = subprocess.run([str(exe)], text=True, capture_output=True)
        print(label, result.stdout, flush=True)
        if label == 'baseline':
            assert result.returncode != 0 and result.stdout.count('FAIL ') == 3, result.stdout + result.stderr
        else:
            assert result.returncode == 0 and result.stdout.count('PASS ') == 3, result.stdout + result.stderr
print('FINAL regression proof passed' + ('' if have_baseline else ' (baseline half skipped)'))
