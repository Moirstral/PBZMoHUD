# PBZMoHUD

影之刃零：水墨弧形血条、杀气条与图标 HUD。当前版本 1.0.1。

- [安装](#安装)
- [配置与保存](#配置与保存)
- [拖动图标](#拖动图标)
- [ini 全键说明](#ini-全键说明)
- [破防检测](#破防检测)
- [源码与测试](#源码与测试)

## 安装

需要 UE4SS 3.x。配置面板与拖动功能另需 PBZMoConfig（含命令事件与 defer 延后保存协议）。

退出游戏后，将整个 `PBZMoHUD` 目录放进 `ue4ss/Mods/`，保留 `Scripts/`、`lang/`、`enabled.txt`。不要与 `PBZPlayerArcs` 同时启用；安装器只提醒，不会擅自停用其他模组。

开发目录可运行：

```bash
python PBZMoHUD/install_to_game.py
python PBZMoHUD/install_to_game.py --apply --sync
```

默认只预览，`--apply` 才安装，已有目录需 `--sync`；`--mods-dir` 指定 Mods 目录。更新只覆盖代码和翻译，保留已存在的 `Scripts/settings.ini` 与 `enabled.txt`，不删除文件。不会改 UE4SS 的 `settings.ini`，也不会改 PBZMoConfig、示例或其他模组。

## 配置与保存

配置只写在 `PBZMoHUD/Scripts/settings.ini`。

- PBZMoConfig 默认 `HOME` 显隐、`T` 应用当前模组、`R` 恢复默认；快捷键与界面语言以框架设置为准。
- 打开面板后在左侧选 `PBZMoHUD`。修改立即预览，但只有应用修改才写盘；放弃修改会回滚。
- 配置页打开或临时收起时，已启用的控件保持显示，不受游戏 HUD 淡出和满值计时影响。主动关闭的弧线、图标不强行显示；关闭配置页后恢复正常显隐规则。
- 未装框架时 HUD 仍可运行：直接编辑本模组 ini，没有实时面板、拖动按钮或保存请求。
- 初次运行缺少 ini 时使用默认值，不自动生成或改写配置。旧 `PBZPlayerArcs` 的配置不自动迁移，也不会被本模组修改。

## 拖动图标

在配置页「拖动图标」一行点击「开始拖动」，面板临时收起后进入拖动模式。

- 左键拖整组，右键拖单个图标，中键将命中组恢复自动锚点、清零组内偏移；松开鼠标即结束本次拖动，仍留在拖动模式。
- 按 `ESC` 回到面板即可退出（`ESC` 仅拖动模式生效，不做全局快捷键）；换到其他模组、关闭面板或框架重载也会结束拖动。
- 拖动和退出都不自动写 ini：回到面板选择应用，位置才持久化；选择放弃则回到之前位置。换图或框架重载会取消当前拖动，未提交的拖动位置不保证保留。
- 拖动模式期间游戏暂停，屏幕盖一层半透明黑色遮罩（游戏自身的 HUD 在遮罩下方），本模组的弧线、图标和提示显示在遮罩之上；显示鼠标光标并屏蔽移动/视角输入，操作不透传给游戏。
- 退出拖动后解除暂停、恢复原输入状态（进入前游戏已处于暂停则保持不动）。提示随框架有效语言切换。

## ini 全键说明

一行一个 `Key = value`；布尔值 `true` / `false`，颜色 `#RRGGBB`。注释放在独立的分号行，不要写在值后面。范围和步长以面板为准。像素尺寸按 1080p 基准随界面比例缩放。`Hp` 表示血量，`Qi` 表示杀气。

### `[预设]`

- `Layout=normal`：`normal` 血量左/杀气右，`mirror` 两侧对调，`ipsilateral` 两条同在左侧。
- 选择预设会一并写入对应的 `HpArcSide`、`QiArcSide`、`HpArcSpan`、`QiArcSpan`、`HpOffsetX`、`QiOffsetX`。

### `[行为与位置]`

- `FollowCharacter=true`：锚点跟随人物；`false` 使用固定屏幕锚点。
- `FollowSmoothing=0.10`：跟随平滑时间，0..1 秒。
- `FixedAnchorX=0.50`、`FixedAnchorY=0.55`：固定锚点占屏幕宽高的比例，0..1。
- `AnchorHeight=15`：人物投影的世界高度偏移，-100..300（UE 世界单位，约 1 厘米/单位，非像素）。
- `AnchorOffsetX=0`、`AnchorOffsetY=0`：整体锚点偏移，-600..600 像素。

### `[两条弧独立设置]`

- `HpArcEnabled=true`、`QiArcEnabled=true`：分别启用；关闭后停止该条分段更新。
- `HpArcSide=left`、`QiArcSide=right`：`left` / `right` 决定弧在自身圆心哪侧。
- `HpRadius=195`、`QiRadius=195`：半径，60..600。
- `HpThickness=12`、`QiThickness=12`：粗细，2..30。
- `HpRotation=0`、`QiRotation=0`：整条弧绕自身圆心旋转，-180..180 度，笔锋和残影一起转。
- `HpFillDirection=normal`、`QiFillDirection=normal`：`normal` 正向 / `reverse` 反向，按弧自身段序，不绑定屏幕方向。
- `HpOffsetX=0`、`HpOffsetY=0`、`QiOffsetX=0`、`QiOffsetY=0`：旋转之后叠加的屏幕偏移，-600..600。
- `HpArcSpan=60`、`QiArcSpan=60`：弧跨度，30..180 度。
- `HpSegments=45`、`QiSegments=45`：分段数，8..96。
- `HpColor=#D6D2C6`、`QiColor=#D9A62E`：基础颜色。
- `HpTrackColor=#0A0908`、`QiTrackColor=#0A0908`：底轨颜色。
- `HpWarnColor=#E0301E`、`QiWarnColor=#E0301E`：低量警告色。
- `HpBarOpacity=0.75`、`QiBarOpacity=0.75`：填充透明度，0.05..1。
- `HpTrackOpacity=0.45`、`QiTrackOpacity=0.45`：底轨透明度，0..1。
- `HpGhostOpacity=0.55`、`QiGhostOpacity=0.55`：残影透明度，0..1。
- `HpGhostColor=#8B1A1A`、`QiGhostColor=#AD8322`：残影颜色，默认血量暗红、杀气暗金；破防期间杀气残影跟随破防颜色。
- `HpVirtualColor=#C8141E`：临时损血颜色。斩马刀受击后尚未真正扣除的血量接在血量填充末端显示，笔锋停在它的末端。
- `HpShowGhost=true`、`QiShowGhost=true`：显示损失残影。
- `HpShowTip=true`、`QiShowTip=true`：显示笔锋。
- `HpTipScale=1.8`、`QiTipScale=1.8`：笔锋尺寸倍率，0.3..3。
- `HpTipAngle=-15`、`QiTipAngle=-15`：笔锋自身角度，-90..90 度。
- `WarnThresholdHp=0.30`、`WarnThresholdQi=0.25`：低量警告阈值，当前值/上限低于阈值时生效。

### `[共有外观与显隐]`

- `BrushJitter=0`：笔触抖动幅度，0..1。
- `StrokeOverlap=9.5`：笔触重叠量，1..24。
- `GhostSpeed=0.35`：残影追随时间，0.01..3 秒。
- `GhostDelay=0.8`：残影回收延迟，0..3 秒；掉血后先保持残影再回收，连续掉血刷新保持，`0` 立即回收。
- `WarnFlashSpeed=1.8`：低量警告闪烁速度，0.2..8。
- `WarnFlashAmount=0.65`：低量警告闪烁幅度，0..1；破防色本身不闪烁。
- `Visibility=dynamic`：`dynamic` 跟随游戏 HUD 并在满值计时后隐藏各条；`hud` 仅跟随游戏 HUD。
- `HideDelay=3`：满值隐藏等待时间，0..30 秒。

### `[图标]`

- `MedicineHud=true`：药瓶组开关。
- `PureIcon=true`：精纯杀气图标开关。
- `BulletIcon=true`：暗源图标开关。
- `UltChargeBar=true`：精纯杀气的充能填充；`PureIcon` 关闭时无效。
- `IconScale=1`：图标缩放，0.5..3。
- `MedicineHudX=-1`、`MedicineHudY=-1`：药瓶组锚点。
- `UltHudX=-1`、`UltHudY=-1`：精纯杀气与暗源共用锚点。
- 以上四项 `-1` 表示自动布局，可拖动设置，范围 -10000..20000。
- `Med1OffX=0`、`Med1OffY=0`、`Med2OffX=0`、`Med2OffY=0`：两个药瓶的组内偏移。
- `Ult1OffX=0`、`Ult1OffY=0`：精纯杀气组内偏移。
- `Ult2OffX=0`、`Ult2OffY=0`：暗源组内偏移。
- 以上八项范围 -800..800；右键拖动分别调整。
- `DragIcons` 是面板命令，不是 ini 配置键。

### `[原生条与数字]`

- `NativeBars=pin`：`pin` 固定长度 / `dynamic` 保持游戏长度 / `hide` 隐藏原生条及底图。
- `HudBarWidth=-1`：`pin` 时 `-1` 使用每条最初长度；有效指定宽度从 48 起，最大 4000。
- `NativePinRecover=true`：连续写入/读回失败时允许恢复重绑；关闭仍保留正常的控件身份检测。
- `HudNumbers=true`：显示当前值与最大值。
- `HudNumberStyle=center`：`center` 居中 / `side` 侧边。
- 隐藏原生条时，数字跟随对应弧的旋转与偏移；对应弧关闭则数字回到游戏条位置。

### `[破防与调试]`

- `BreakHint=true`：杀气破防提示，`QiArcEnabled` 关闭时不采样。
- `QiBreakColor=#FF3B30`：破防颜色，优先于低量警告与基础色。
- `QiBreakTrackColor=#6B1410`：破防期间杀气弧底条颜色（暗红），破防结束后恢复为 `QiTrackColor`。
- `BreakDemo` 是面板命令（杀气条分组）：临时收起面板，清空杀气弧并显示破防色（含底条）3 秒后自动放回面板；不会让人物真的破防，不是 ini 配置键。`BreakHint` 关闭时该命令不可用。
- `Debug=false`：开启后写诊断到 `PBZMoHUD.log`，平时不要开启。

## 破防检测

只读三路游戏信息：Hitreact 破防状态标签、ASC 的 `CharacterState.Stand.Break` 标签、名字含 `Deflect_Break` 的当前动画蒙太奇。约 15Hz 检测，以 0.16 秒宽限连接短状态。

不同游戏版本可能改变标签或动画名；离线用例不能代替游戏内破防验收。本模组不会修改角色属性、战斗状态或游戏 HUD 特效。

## 源码与测试

源码重构自相邻 `../PBZPlayerArcs` 的 v0.4.0；旧仓库及其标签独立保留。历史更新记录见 `CHANGELOG.md`；许可证见 `LICENSE`。

工作区离线回归（`tools/luavm/package` 提供 wasmoon，无 Lua 本机环境也能执行）：

```bash
node PBZMoHUD/tests/run.js compile
node PBZMoHUD/tests/run.js
python PBZMoHUD/tests/install.py
```

离线用例不覆盖游戏内渲染与输入：旋转位置、输入切换、拖动、真实破防，以及升级/换装备后的原生条长度仍需在游戏内验收。
