# Vectra

桌面磁贴小组件（MacroSTAR Studio）· Flutter + Win32 版

## 构建

```
flutter build windows --release --no-pub
```

产物：`build\windows\x64\runner\Release\vectra.exe`（连同 DLL 与 `data\` 一起分发）。

打发布包（Release 文件夹 + 便携版，不再出安装版）：

```
tool\build_release.bat
```

产物：
- `build\windows\x64\runner\Release\`（整个文件夹就是发布版，解压即用）
- `installer\out\Vectra-<版本号>-便携版.exe`

## 测试

```
flutter test --no-pub
node test/js/lrc_verify.js   # 歌词解析纯函数验证
```
