"""开发用一键部署：编译 → 覆盖到本机正式安装 → 启动。

与 tool/build_release.bat 的区别：**不打包安装包**（省掉 lzma2 压缩那 20 秒），
直接覆盖程序文件然后拉起来，专供"改完立刻看效果"。

用法：
    python tool/deploy_dev.py            # 编译 + 部署 + 启动
    python tool/deploy_dev.py --skip     # 跳过编译（刚编过就用这个）

约定（用户明确要求）：**每次改完都要自动打开给他看成品**。
所以改完代码的收尾动作是跑这个脚本，而不是只编译完就结束。
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
RELEASE = ROOT / "build" / "windows" / "x64" / "runner" / "Release"
TARGET = pathlib.Path(r"C:\Users\81157\Glance")   # 本机的正式安装位置
FLUTTER = r"C:\src\flutter\bin\flutter.bat"
DLLS = ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip", action="store_true",
                    help="跳过编译，直接用现有产物部署")
    args = ap.parse_args()

    # 1. 先关掉运行中的实例：它占着要被覆盖的 exe 和 dll
    subprocess.run(["taskkill", "/F", "/IM", "glance.exe", "/T"],
                   capture_output=True)
    time.sleep(1.0)

    # 2. 编译
    if not args.skip:
        print("[1/3] flutter build windows --release ...")
        r = subprocess.run([FLUTTER, "build", "windows", "--release", "--no-pub"],
                           cwd=str(ROOT), capture_output=True, timeout=1800)
        if r.returncode != 0:
            print(r.stdout.decode("gbk", errors="replace")[-1500:])
            print("[ERROR] 编译失败")
            return 1
    else:
        print("[1/3] 跳过编译（--skip）")

    exe = RELEASE / "glance.exe"
    if not exe.exists():
        print(f"[ERROR] 找不到产物 {exe}")
        return 1

    # 3. 覆盖程序文件（userdata 原样保留）
    print("[2/3] 覆盖部署 ...")
    TARGET.mkdir(parents=True, exist_ok=True)
    for name in ("glance.exe", *DLLS):
        src = RELEASE / name
        if src.exists():
            shutil.copy2(src, TARGET / name)
    data = TARGET / "data"
    if data.exists():
        shutil.rmtree(data)
    shutil.copytree(RELEASE / "data", data)

    # 4. 拉起来给用户看
    print("[3/3] 启动 ...")
    subprocess.Popen([str(TARGET / "glance.exe")])
    time.sleep(3.0)
    print(f"已部署并启动：{TARGET / 'glance.exe'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
