# Legacy cache layout example

这里是一个 **自制、非游戏资源** 的 ACGPower-compatible cache 目录示例，只用于说明路径与 `.ext` 元数据格式。

真实 ACGPower GBF cache 通常类似：

```text
cache/gbf/
└── https/
    └── assets/
        └── ...
            ├── resource.png
            └── resource.png.ext
```

本项目不要求把真实旧缓存复制到仓库，只需要在 `.env` 中指向已有目录：

```bash
GBF_LEGACY_CACHE_ROOTS="/mnt/f/Programs/acgpower-x64/cache/gbf;/mnt/f/Programs/acgpower/cache/gbf"
```

没有旧缓存时：

```bash
GBF_LEGACY_CACHE_ROOTS=""
```

本目录里的 `demo.js` 是项目自己生成的演示文本，不属于 GBF/ACGPower。
