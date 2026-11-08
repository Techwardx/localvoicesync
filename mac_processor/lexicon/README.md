# 本地词库

转写纠错用的**离线词表**，全部随仓库分发，运行时不联网、不上传任何内容。

## 为什么选 THUOCL

`thuocl/` 是「清华大学开放中文词库」（THU Open Chinese Lexicon），MIT 许可，
由清华 NLP 实验室人工筛选并带 DF 词频。相比通用大词典，它按生活领域分类，
覆盖**饮食、汽车、地名、IT、医学、财经、成语、法律、动物、历史名人、诗词**，
更贴合家庭日常语音备忘里会出现的专名，而且低频噪声词少得多。

- 上游仓库：https://github.com/thunlp/THUOCL
- 许可：MIT，见 [`thuocl/LICENSE`](thuocl/LICENSE)（Copyright (c) 2018 THUNLP）
- 官方授权说明：「面向国内外大学、研究所、企业、机构以及个人免费开放，可用于研究与商业」
- 数据抓取时间：2026-11-07，取自上游 `master` 分支 `data/`，**未做内容修改**

按要求保留出处声明：

> 韩世依, 张钰晖, 马云山, 涂存超, 郭志芃, 刘知远, 孙茂松. THUOCL：清华大学开放中文词库. 2016.
>
> Shiyi Han, Yuhui Zhang, Yunshan Ma, Cunchao Tu, Zhipeng Guo, Zhiyuan Liu,
> Maosong Sun. THUOCL: Tsinghua Open Chinese Lexicon. 2016.

### 文件格式

每行 `词<Tab>DF值`，DF 是该词出现在多少篇文档里，可直接当词频用。
注意 `THUOCL_diming.txt` 是上游原文件，**带 UTF-8 BOM 且用 CR 换行**，
加载器统一用 `utf-8-sig` + `splitlines()` 处理，不要改成 LF 后再比较哈希。

| 文件 | 领域 | 词条 |
| --- | --- | --- |
| THUOCL_IT.txt | IT | 16,000 |
| THUOCL_animal.txt | 动物 | 17,287 |
| THUOCL_caijing.txt | 财经 | 3,830 |
| THUOCL_car.txt | 汽车 | 1,752 |
| THUOCL_chengyu.txt | 成语 | 8,519 |
| THUOCL_diming.txt | 地名 | 44,805 |
| THUOCL_food.txt | 饮食 | 8,973 |
| THUOCL_law.txt | 法律 | 9,896 |
| THUOCL_lishimingren.txt | 历史名人 | 13,658 |
| THUOCL_medical.txt | 医学 | 18,749 |
| THUOCL_poem.txt | 诗词 | 13,703 |

合计约 11.2 万条、2.6 MB。

## custom.txt

THUOCL 的分类里没有「节日 / 家庭称谓 / 生活场所」这几类，而它们恰恰是家庭备忘
最容易听错的专名（例如 `万圣洁` 应为 `万圣节`）。`custom.txt` 是**本项目自建**的
一小份兜底词表（约 120 条，公有领域事实性词汇，无第三方版权），不是让用户维护的
词表 —— 主体始终是上面 11.2 万条自动加载的词库，加上流水线自己从历史
`tags` / `aliases` 里积累的家庭专名。

格式：每行一个词，`#` 开头是注释。想加自己家的专属名词，直接往这个文件末尾追加即可，
重启服务生效（10 分钟缓存）。
