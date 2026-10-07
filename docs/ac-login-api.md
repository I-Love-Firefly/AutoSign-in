# ac.xmu.edu.my 登录入口接口记录

检查时间：2026-10-06 15:55（Asia/Shanghai）。证据来源：用户当前 Codex 内置浏览器中的实时 DOM、表单属性和全部内联 JavaScript。只读分析，未提交登录、未使用真实密码、未改变登录状态。

## 页面与接口

- 页面地址：`https://ac.xmu.edu.my/index.php`
- 页面标题：`XMUM Academic Affairs Online System`
- 系统用途：页面说明使用 staff ID 或 student ID 登录教务系统。
- 这是独立的 Academic Affairs 登录入口。不能将它当作 `srun.xmu.edu.my` 校园网认证接口，或直接套用 `cas.xmu.edu.my` 的 CAS RSA / 票据流程。

当前登录页只发现一个业务接口：

| 名称 | 方法 | URL | 用途 |
| --- | --- | --- | --- |
| 登录 | POST | `https://ac.xmu.edu.my/index.php?c=Login&a=login` | 提交用户名、密码与账号类别 |

入口页面本身通过 GET 加载。提交采用浏览器原生表单，非 AJAX；表单 target 为空（当前窗口），编码 `application/x-www-form-urlencoded`。

## 参数

URL 查询参数为 `c=Login`、`a=login`。登录数据放在 POST 请求体中：

| 请求体字段 | 来源 | 说明 |
| --- | --- | --- |
| `username` | 文本输入框 `#username` | 学生 ID 或职工 ID |
| `password` | 密码输入框 `#password` | 输入的密码原值；页面未做前端 RSA、摘要或其他加密变换，HTTPS 保护传输 |
| `user_lb` | 选择框 `#user_lb` | `Student`、`Teacher`、`Admin`，取值区分大小写；当前显示 Student |

仅用于说明的虚构示例：

```http
POST /index.php?c=Login&a=login HTTP/1.1
Host: ac.xmu.edu.my
Content-Type: application/x-www-form-urlencoded

username=example&password=password&user_lb=Student
```

真实参数需要正确进行表单 URL 编码，不能直接拼接特殊字符。密码不放在 URL 查询参数里。正常浏览器会携带该站点已有的 Cookie；当前未确认服务器要求的 Cookie 名称或会话机制，不能推断为无状态接口。

## 前端行为

表单：`name=form1`、`id=form1`，`onsubmit="return fnOnSubmit(this);"`。提交按钮 `id=loginbtn`，无 name，因此不作为请求体字段。

`fnOnSubmit(form)`：

1. 用户名或密码是空字符串时阻止提交。
2. 把焦点移至缺失字段，提示 `Please key in username and password to login.`。
3. 两者非空则禁用提交按钮，然后允许原生表单提交。

`fnFocus()`：页面加载后优先聚焦空用户名框，否则聚焦空密码框。兼容 `addEventListener` 和旧式 `attachEvent`。

页面没有外部 script 引用、隐藏 input 字段、可见验证码/二次验证字段或前端密码加密逻辑。此结论仅针对当前登录页，不排除服务器在后续响应中要求额外验证。

## 2026-10-06 登录后及手机联调补充

用户登录后默认个人信息页为 `https://ac.xmu.edu.my/student/index.php?c=Default&a=inf`。课程清单页为 `https://ac.xmu.edu.my/student/index.php?c=Default&a=Wdkc`，菜单中另有网格课表 `a=Kb`。

| 名称 | 方法 | URL | 已确认用途 |
| --- | --- | --- | --- |
| 学生身份 | GET | `https://ac.xmu.edu.my/student/index.php?c=Default&a=inf` | 读取 Student ID，用于与所选 Campus ID 比较 |
| 课程列表 | GET | `https://ac.xmu.edu.my/student/index.php?c=Default&a=Wdkc` | 当前学期 Course List，服务端 HTML 表格 |
| 网格课表 | GET | `https://ac.xmu.edu.my/student/index.php?c=Default&a=Kb` | 按星期与小时展示 Timetable |
| 注销 | GET | `https://ac.xmu.edu.my/student/index.php?c=Default&a=logout` | 退出当前 AC 会话；菜单链接已确认，应用对自己的独立会话使用 |

课程页的 `select#tm_id` 当前选中 `value=202609`（显示 2026/09）。字段包含 Course Code、Course Name (by group)、Time & Venue、Teaching Week。课表解析使用星期、12 小时 AM/PM 时间、括号中的教室与 Week 周范围；若无法完整解析，拒绝覆盖旧缓存。尚未验证学期切换请求参数，不根据选择框名称猜测其完整请求。

手机独立会话真实验证已通过登录、身份核验、课程读取、保存及重启恢复。个人信息行使用 th 字段名及两个 td；身份解析应读取直接子单元格，不能假定两个 td 分别是字段名和值。课程页是普通 HTML，不应按 JSON API 解码。每个账号使用隔离 Cookie 会话，完成后尝试调用注销并清除本地 Cookie；服务器端注销完成状态未另行探测。

## 未验证的部分（更新）

- 登录表单提交、学生身份页面与课程读取已在手机验证；错误密码的服务器 HTTP 状态/原始提示、Cookie 名称及其他账号类别仍未确认。应用以读取到匹配 Student ID 作为成功依据。
- 成绩、考试等其他功能未实现；当前课表页不提供签到开放状态，不能用于代替 acad 签到查询。
- 任何后续接入都应先检查实际登录后响应；避免因页面标题相似而混用已实现的 acad/CAS 认证逻辑。

本文不记录真实账号、密码、Cookie 或登录票据。
