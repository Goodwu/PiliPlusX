# OHOS 实机控制条操作记录

适用设备：实体机 `2PM0223A18006914`。`127.0.0.1:5555` 是模拟器，不用于这条验收。

## 操作原则

- 控制条会在很短时间内自动隐藏。
- 不要在“唤出控制条”和“点击目标控件”之间插入等待、截图传输或日志查询。
- 所有连续操作放进同一条 HDC 命令，必要时只在最后一步完成后等待并截图。
- 坐标以刚刚生成的当前方向截图为准；横竖屏、状态栏和视频区域变化后不能复用旧坐标。
- 如果需要确认控件边界，先唤出控制条，再立即 `dumpLayout`；dump 结束后控制条可能已经超时，不能把 dump 后的状态当作仍可点击。

## 标准 HDC 操作模板

```sh
HDC=/Users/wuweiwei1/bin/hdc

# 唤出控制条后立即点击目标控件；把坐标替换为当前截图中的坐标
$HDC -t 2PM0223A18006914 shell uitest uiInput click <视频区域X> <视频区域Y>
$HDC -t 2PM0223A18006914 shell uitest uiInput click <目标控件X> <目标控件Y>

# 目标操作完成后再等待和抓取状态
sleep 2
$HDC -t 2PM0223A18006914 shell hilog -x | tail -100
```

全屏按钮测试必须使用同一条连续命令，不能先点击视频、等待几秒后再点击全屏。验证真正全屏要同时检查：显示旋转、窗口宽高、详情页内容是否隐藏和视频是否占满全屏。详情页视频区域横向铺满不等于全屏播放。

## 当前已确认的辅助命令

```sh
# 当前画面截图
$HDC -t 2PM0223A18006914 shell snapshot_display -f /data/local/tmp/current.jpeg
$HDC -t 2PM0223A18006914 file recv /data/local/tmp/current.jpeg /tmp/current.jpeg

# 控件树（只读诊断）
$HDC -t 2PM0223A18006914 shell uitest dumpLayout -p /data/local/tmp/layout.json
$HDC -t 2PM0223A18006914 file recv /data/local/tmp/layout.json /tmp/layout.json
```

不要用 `uiInput input_text` 或 `uiInput keyevent` 这类不存在的子命令；本环境支持的是 `click`、`doubleClick`、`longClick`、`inputText`、`text`、`keyEvent`。
