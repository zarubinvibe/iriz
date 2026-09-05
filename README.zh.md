# iriz

开口说，字就出现。识别在你自己的 Mac 上完成，不去别人的云里绕一圈。

[English](README.md) · [Русский](README.ru.md)

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/zarubinvibe/iriz?style=flat&color=C9A87A)](https://github.com/zarubinvibe/iriz/stargazers) [![Status](https://img.shields.io/badge/status-working-brightgreen.svg)](https://github.com/zarubinvibe/iriz) [![Olympuz](https://img.shields.io/badge/olympuz-family-B8D6EA.svg)](https://github.com/zarubinvibe/athena#olympuz-family)

<p align="center"><img src="docs/assets/pantheon/hero.png" alt="白色大理石的伊里斯长着大理石翅膀，站在古典石柱旁，金色的声音丝带落进石板上的凹槽里" width="100%"></p>

<!-- owner-welcome:start -->

> 你好。我是个律师，也写代码，而且打字打得很多。打得不算慢，可一天下来还是发现，半天时间都花在敲字上了。
>
> 试过几个工具之后，我明白了一件很简单的事：我说出来的比敲出来的准。敲字的时候我在挑词；说话的时候不挑，念头是整的，另一头的模型也更明白我要什么。挡在中间的只有一件事，隐私。所以这里把界划清楚了：该留在我这儿的，只在我自己的机器上识别；出去的，只有我自己送出去的那部分，比如翻译，或者把我说的话整理成任务。
>
> 还有最开始那件小事：我总忘了切输入语言，一句话敲成了另一套布局。在这儿它自己会改回来。
>
> — Filipp Zarubin

<!-- owner-welcome:end -->

## 目录

- [这是什么](#这是什么)
- [它解决什么问题](#它解决什么问题)
- [最大的优势](#最大的优势)
- [工作流程](#工作流程)
- [快速开始](#快速开始)
- [简单对比](#简单对比)
- [简单词汇](#简单词汇)
- [安全与隐私](#安全与隐私)
- [局限](#局限)
- [点亮星标与参与](#点亮星标与参与)

<!-- beginner-readme:start -->

## 这是什么

iriz 待在菜单栏里，做三件事。一句话敲成了另一套键盘布局，它换回来。听写：按一下键，说话，再按一下，字就落在光标那里。第三件是把颠三倒四的一段口述整理成能交给智能体的任务。识别在 Mac 本机完成，跑在 Neural Engine 上，用的是 CoreML 格式的 Parakeet TDT v3。

先把丑话说在前面：这套东西对中文用户基本用不上。语音模型认的是十八种欧洲语言，里面没有中文；自动换布局管的是英俄这一对，跟拼音、五笔这类中文输入法完全是两回事；应用界面目前只有俄文。

## 它解决什么问题

云端听写把口语收拾得比本地干净，这是实话。可传上去的东西，是和委托人的对话、是起草到一半的文书、是名字和金额。对一个受职业保密约束的人来说，这笔交换怎么算都不划算。所以识别留在本机，唯一一次联网由你按按钮开始。

## 最大的优势

**最大的优势：** 识别在你自己的机器上跑，听写期间由识别库里的一道总闸切断联网，不是靠一句承诺。

**为什么这样更好：** 开关叫 `DownloadUtils.enforceOffline`，位置在识别库内部，连下载失败的时候也会自己归位。光有文档不算数：自检脚本盯住编译好的二进制里那一组网络符号，再去问系统，运行中的应用手上有没有一个套接字。

## 工作流程

按下热键，说完一句，再按一次。文字落在光标刚才闪的地方：邮件、聊天窗口、终端都行。没落进去也不要紧，菜单栏下面那条小提示会展开成一块面板，从那里把文字整段拿走。

<!-- workflow-diagram:start -->

<p align="center"><img src="docs/assets/pantheon/takt-zh.png" alt="四块大理石板排成一行，每块刻着一个步骤，一条从左边进来的金色声音丝带把它们串起来" width="100%"></p>

<!-- workflow-diagram:end -->

| 阶段 | 会发生什么 |
|---|---|
| 1. 按键 | 一个键，在哪个程序里都一样 |
| 2. 说话 | 你说话，小提示条告诉你它在听 |
| 3. 识别 | Mac 用自己的芯片把话变成字 |
| 4. 落字 | 文字落在光标刚才闪的地方 |

### 第 1 步：按下你的那个键

默认是右边的 Command。按下去就行，Mac 上别的什么都不用改：不用先开窗口，也不用先把光标放到哪儿。这个键要是被占了，在引导里当场换掉，不用去设置里翻。

**你会得到：** 一个在编辑器、邮件和终端里都答应的键。

### 第 2 步：说出来

光标旁边会出现一条小提示，上面的波形跟着你的声音走，能看出来它在听，不用猜。声音只在内存里待到识别完成，不写进磁盘。

**你会得到：** 一段只活几秒、什么都不留下的录音。

### 第 3 步：Mac 本机识别

识别跑在这台 Mac 的 Neural Engine 上：七秒话大约一成秒就出结果。什么都不往外发；听写进行的时候，识别库里的下载开关是关着的。

**你会得到：** 一份从没离开过你机器的转写。

### 第 4 步：文字落进输入框

它进的是你本来就待着的那个输入框：邮件、聊天窗口、终端。要是那个框不收，小提示会展开成一块面板，整段文字都在里面，点一下就进剪贴板。你伸手去拿的这段时间里，它不会丢。

**你会得到：** 文字进了框，或者还能从面板里整段拿走。

## 快速开始

需要一台 macOS 14 或更新的 Mac，还有三项系统权限：麦克风、辅助功能、输入监控。从源码构建另外要 Xcode 和 Swift 6。接下来有三条路，走哪条都行。

```bash
git clone https://github.com/zarubinvibe/iriz.git ~/iriz
cd ~/iriz
bash install.sh          # просто терминал, без единого агента
code .                   # или откройте папку в редакторе
claude                   # или пустите агента: он проведет установку разговором
```

不想构建？到 Releases 拿现成的磁盘映像：打开，把图标拖进 Applications。没有 Git？下载 [ZIP](https://github.com/zarubinvibe/iriz/archive/refs/heads/main.zip)，解压后在里面执行同一条命令。第一次用？在 Claude Code 里打开项目并运行 `/iriz-setup`：安装以对话的方式进行，一次问一个问题，没有你点头不会装任何东西。

第一次做这件事？[上手引导](docs/ONBOARDING.zh.md) 会一步一步带你走完第一次运行，并写清楚每条命令之后你会看到什么。

**你会得到：** 安装脚本先说清楚这是什么，再看你的机器缺什么，跑一遍 `bash scripts/selfcheck.sh --selftest`，最后告诉你下一步该做什么。你不开口，它什么都不装。真要构建，加一个参数：`bash install.sh --build`。

## 简单对比

| 方案 | 适合什么时候 | 你会得到 | 语音去哪儿 | 管不管布局 | 代价 |
|---|---|---|---|---|---|
| **iriz** | 口述的是工作材料，不能交出去 | 布局、本机听写、口述变任务 | 哪儿也不去，Mac 本机识别 | 管，英俄这一对 | 俄语优先，还没做公证 |
| 自己手打 | 就一句话，偶尔一次 | 每个字都在你手里 | 哪儿也不去 | 不管 | 长文本要吃掉一晚上 |
| Punto Switcher | 只需要换布局 | 多年打磨的布局纠正 | 哪儿也不去 | 管 | 完全没有听写 |
| macOS 自带听写 | 偶尔说一两句 | 系统里已经有了 | 除非开了离线模型，否则去 Apple | 不管 | 专业词很弱，也不会整理成任务 |
| Wispr Flow 这类 | 把颠三倒四的话理顺 | 清洗效果目前最好 | 它们的服务器 | 不管 | 当事人的名字跟着文本一起走 |
| 本地 Whisper 应用 | 不想用云的听写 | 同样在你机器上算 | 哪儿也不去 | 不管 | 不纠正布局，也不把口述整理成任务 |

## 简单词汇

| 词 | 简单解释 |
|---|---|
| Repository | 仓库：Git 保存并记录版本的项目文件夹 |
| Terminal | 终端：你输入命令的窗口 |
| Command | 命令：给电脑的一条指令 |
| Branch | 分支：不影响 `main` 的另一条修改线 |
| Pull Request | 合并请求：请别人审阅并接受你的修改 |
| Neural Engine | 苹果芯片里只管神经网络的那一块：识别快，机器也不发烫 |
| Parakeet TDT v3 | 把声音变成字的那份模型权重，CoreML 格式。它不在安装包里，第一次用的时候由应用自己下载，大约半个 GB，只下这一回 |

## 安全与隐私

- 录音不落盘：它只活到把你说的话解出来为止。
- 不读屏幕。没有 ScreenCaptureKit，也不截窗口。
- 不读别人应用里的输入框：那项权限是用来判断这个框能不能写字，不是用来把字取出来。
- 你在哪里听写过，不记录。否则磁盘上会攒起你和谁、在什么时候工作的痕迹。
- 粘贴之后，剪贴板放回原样。
- 转写文件的权限是 0700 和 0600，留在你自己的磁盘上。

往外走的只有一件事，而且要你按按钮：识别模型那一次性的下载。提示词模式默认关着；打开它，就等于同意把转写交给你自己装好、自己登录的那个智能体命令行，比如 Codex CLI，走那条路时文本会发到它背后的服务商。翻译走的是同一条路：你说俄语，落下来的是英文。

## 局限

状态：可用，作者每天用它口述。

- 语音模型认十八种欧洲语言，中文不在其中：中文口述它听不懂。
- 自动换键盘布局只管英语和俄语这一对，对拼音、五笔这类中文输入法不适用。
- 应用界面目前只有俄文，说明文档才有中文。
- 只支持 macOS 14 及以上。没有 Windows，没有 Linux，也没有 iPad。
- 还没有做公证：下载来的构建第一次打开要用右键的“打开”。
- 通用二进制里带着 Intel 那一片，可是作者手上没有 Intel 的 Mac，从来没在上面验过。

想看更深的：[一步一步的上手引导](docs/ONBOARDING.zh.md)、[怎么参与](CONTRIBUTING.zh.md)，依赖的许可证在 [THIRD-PARTY](THIRD-PARTY)。

## 点亮星标与参与

觉得有用？给 iriz 点亮星标：[https://github.com/zarubinvibe/iriz](https://github.com/zarubinvibe/iriz)。这只要一秒，却决定别人能不能找到这个项目。

想改点什么？流程很短：先 fork 仓库，建一个分支 branch，提交 commit，推送 push，然后开一个 Pull Request。请不要直接向 `main` 推送，发布闸门会拒绝。

发现问题？到 [https://github.com/zarubinvibe/iriz/issues](https://github.com/zarubinvibe/iriz/issues) 开一个 issue，写清楚你运行了什么、发生了什么。

<!-- beginner-readme:end -->

<!-- pantheon-family:start -->
## Olympuz 家族

这是 [Olympuz 家族](https://github.com/zarubinvibe/athena#olympuz-family) 的公开项目之一。表格里的每一行都可以打开仓库，或者直接下载源码压缩包。

| 类型 | 名称 | 做什么 | 获取 |
|---|---|---|---|
| 项目 | Athena | 可携带的智能体操作系统：在新的 Mac 上重建 Claude 与 Codex 的工作环境。 | [仓库](https://github.com/zarubinvibe/athena) · [ZIP](https://github.com/zarubinvibe/athena/archive/refs/heads/main.zip) |
| 项目 | Helioz | 全天候的智能体工作传送带，带可验证的完成标记和按目标做出的夜间决策。 | [仓库](https://github.com/zarubinvibe/helioz) · [ZIP](https://github.com/zarubinvibe/helioz/archive/refs/heads/main.zip) |
| 项目 | Mnemazine | 本地优先的记忆系统：把原始材料变成可复用的、已核验的知识。 | [仓库](https://github.com/zarubinvibe/mnemazine) · [ZIP](https://github.com/zarubinvibe/mnemazine/archive/refs/heads/main.zip) |
| 项目 | Themiz | 面向俄罗斯诉讼的多智能体助手，本地识别扫描件，五位法学家组成合议审阅。 | [仓库](https://github.com/zarubinvibe/themiz) · [ZIP](https://github.com/zarubinvibe/themiz/archive/refs/heads/main.zip) |
| 项目 | Zeuz | 工作流工厂：把一个想法变成带规则、闸门、可观测性和回放的多智能体系统。 | [仓库](https://github.com/zarubinvibe/zeuz) · [ZIP](https://github.com/zarubinvibe/zeuz/archive/refs/heads/main.zip) |
| 项目 | Lynceuz | 以零成本收集公开网页证据；安全路径走完时，它会给出诚实的理由并停下。 | [仓库](https://github.com/zarubinvibe/lynceuz) · [ZIP](https://github.com/zarubinvibe/lynceuz/archive/refs/heads/main.zip) |
| 项目 | Iriz | macOS 菜单栏听写：语音在你自己的 Mac 上解码，键盘布局自动纠正，口述可以直接变成给智能体的任务。 | [仓库](https://github.com/zarubinvibe/iriz) · [ZIP](https://github.com/zarubinvibe/iriz/archive/refs/heads/main.zip) |
<!-- pantheon-family:end -->

## 许可证

MIT。见 [LICENSE](LICENSE)。
