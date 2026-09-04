# 📦 尼康相机 PacketLogger 抓包文件存放目录 (`captures/`)

> [!IMPORTANT]
> **【隐私与安全保护声明】**  
> 所有 `.pklg` 文件均包含您个人相机的真实物理蓝牙 MAC 地址、真实序列号、设备名称以及由尼康固件与 iPhone
协商生成的真实私有握手密钥（DeviceID / Nonce）。  
> **本项目已在 `.gitignore` 中全局忽略所有 `*.pklg` 文件，严禁将个人真实抓包提交至公共 Git 仓库。**

---

## 🛠️ 使用说明

1. **抓取蓝牙数据包**：
    - 详细抓包操作步骤请参考上级目录教程：[HOW_TO_CAPTURE_PKLG_ON_IPHONE.md](../HOW_TO_CAPTURE_PKLG_ON_IPHONE.md)；
2. **保存与命名**：
    - 抓包完成后，在 PacketLogger 中将文件保存并命名为：
      ```text
      extract_pklg_credentials.pklg
      ```
    - 将其放置在此目录 (`apps/ios/PhotoolsMobile/tools/captures/extract_pklg_credentials.pklg`)；
3. **一键自动提取与验真**：
    - **方案 A（Xcode 自动触发）**：直接在 Xcode 中编译或运行 `PhotoolsMobile` 工程，Pre-Build 脚本将自动检测该抓包并提取凭据到
      `camera_credentials.json`；
    - **方案 B（命令行手动执行）**：
      ```bash
      python3 ../extract_pklg_credentials.py extract_pklg_credentials.pklg --update-config
      ```
