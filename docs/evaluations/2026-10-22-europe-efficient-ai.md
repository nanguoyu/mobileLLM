# 欧洲 Efficient AI 研究组概览

The later [application-generated report](2026-10-23-europe-efficient-ai-app.md) is the current software
demonstration. This independently edited overview retains its original scope and is not app execution evidence.

核对日期：2026-10-22。本文整理 **12 个研究组或明确的研究方向团队，覆盖 9 个国家**，包括英国、瑞士、奥地利、德国、法国、比利时、荷兰、意大利和捷克。它们分别从模型压缩、训练与推理系统、编译器、芯片和端侧学习降低 AI 的计算与存储成本。

名单来自 mobileLLM 动态子代理实际检索的候选，随后由维护者查阅一手来源并修正。**这是经过编辑核对的研究概览，不是应用一次自主完成的输出。** 应用的完整并行执行只交付了 4 组、3 国；补充调查收集了更多资料，但在最终汇总前失败。分阶段执行证据、原始答案及问题见[测试评估](2026-10-22-dynamic-research.md)。

## 模型压缩与训练、推理系统

| 国家 / 城市 | 研究组与负责人 | 具体研究方向 | 近期论文或项目证据 |
| --- | --- | --- | --- |
| 英国 / 爱丁堡 | University of Edinburgh，Large-Scale Machine Learning Systems Group；Luo Mai | 大规模训练、推理服务与模型加载调度 | [负责人及研究组主页](https://luomai.github.io/)；[ServerlessLLM，OSDI 2024](https://www.usenix.org/conference/osdi24/presentation/fu)研究面向本地性的无服务器 LLM 推理。 |
| 瑞士 / 苏黎世 | ETH Zürich，Efficient Architectures and Systems Lab（EASL）；Ana Klimovic | 训练和服务系统、GPU 利用率、数据流水线 | [ETH 2025 年研究访谈](https://inf.ethz.ch/news-and-events/spotlights/infk-news-channel/2025/09/towards-a-more-sustainable-ai-revolution-the-research-for-efficient-ai-is-essential.html)介绍 Sailor、Modyn、Mixtera 等工作及效率目标。这里引用官方介绍，不将尚未逐篇核对的 DeltaZip 署名作为依据。 |
| 瑞士 / 苏黎世 | ETH Zürich，Scalable Parallel Computing Laboratory（SPCL）；Torsten Hoefler | 并行计算系统、量化与高效 LLM 推理 | [组主页](https://spcl.inf.ethz.ch/)；[QuaRot，NeurIPS 2024](https://htor.inf.ethz.ch/publications/index.php?pub=526)研究权重、激活和 KV cache 的 4 bit 量化。该论文是多机构合作成果，不能全部归于单一研究组。 |
| 奥地利 / Klosterneuburg | ISTA，Alistarh Group / Deep Algorithms and Systems Lab（DASLab）；Dan Alistarh | 稀疏与量化表示上的高效训练、推理和压缩 | [ISTA 官方组页](https://ist.ac.at/en/research/alistarh-group/)明确上述方向，并列出 LLMQ、推测解码和 Panza 等近期工作。具体论文的版本和实验数字需要在选定主题后逐篇核对。 |

对 mobileLLM 的阅读优先级判断是：量化、稀疏和低精度执行先看 DASLab 与 SPCL；模型加载、服务调度和数据流水线先看 Edinburgh 与 EASL。这个排序依据研究主题与项目问题的关联，尚未比较这些方法在 iPhone、MLX 或 llama.cpp 上的实际效果。

## 编译器与高效视觉模型

| 国家 / 城市 | 研究组与负责人 | 具体研究方向 | 近期论文或项目证据 |
| --- | --- | --- | --- |
| 法国 / Grenoble | Inria / LIG，CORSE；Fabrice Rastello | 编译优化、稀疏计算、受限硬件上的 AI 部署 | [CORSE 2025 年度报告](https://radar.inria.fr/report/2025/corse/index.html)明确团队负责人并列出 DeepGreen 等部署项目；子代理还检索到 [HOLIGRAIL](https://project.inria.fr/holigrail/) 合作项目。Christophe Guillon 参与项目不足以证明他与 Rastello 共同担任组负责人。 |
| 法国 / Grenoble | Inria，Thoth；Julien Mairal | 降低机器学习模型的计算和数据需求，视觉学习、优化算法 | [Thoth 2025 年度报告](https://radar.inria.fr/report/2025/thoth/index.html)明确负责人及效率研究目标，列有 ARSENIC 等软件工作。其效率范围包括视觉和统计学习，不应因不专门研究 LLM 而剔除。 |
| 意大利 / Torino | Politecnico di Torino，Visual and Multimodal Applied Learning Lab（VANDAL）；Tatiana Tommasi | 视觉模型剪枝、初始化阶段压缩和知识迁移 | [学校 2025 年报道](https://www.polito.it/ateneo/comunicazione-e-ufficio-stampa/poliflash/dal-laboratorio-vandal-la-ricerca-che-rende-l-ai-piu-leggera)介绍《A Second-Order Perspective on Pruning at Initialization and Knowledge Transfer》及 ICIAP 2025 获奖情况。模型压缩后能否保留迁移能力是其具体问题。 |

这三类工作对移动应用的作用不同。CORSE 更接近算子和编译执行效率；Thoth、VANDAL 更适合研究视觉编码器、小模型学习和压缩后的泛化能力。视觉论文中的效率收益不能直接当作 LLM 推理收益。

## 芯片、软硬件协同与端侧学习

| 国家 / 城市 | 研究组或团队与负责人 | 具体研究方向 | 近期论文或项目证据 |
| --- | --- | --- | --- |
| 德国 / Garching、Munich | TUM，Chair of AI Processor Design（AI-Pro）；Hussam Amrouch | 低能耗 AI 芯片、脑启发计算、器件与算法协同 | [组主页](https://www.ce.cit.tum.de/en/aipro/welcome/)；[TUM 2025 年芯片报道](https://www.tum.de/aktuelles/alle-meldungen/pressemitteilungen/details/ki-chip-fuer-dezentrale-nutzung-ohne-cloud-entwickelt)介绍本地计算芯片，并列出《Domain-Specific Hyperdimensional RISC-V Processor for Edge-AI Training》。 |
| 德国 / Darmstadt | TU Darmstadt，Hardware for Artificial Intelligence；Grace Li Zhang | 高效软硬件架构、AI 加速器、存内与神经形态计算 | [学校人员页](https://www.etit.tu-darmstadt.de/kontakt_details_121280.de.jsp)确认当前职位和方向；[hessian.AI 的 LogiNet 公告](https://www.hessian.ai/hessian-ai-member-prof-grace-li-zhang-awarded-erc-starting-grant/)发表于 **2025-09-04**，不是子代理写的 2024 年。这是项目证据，不是已测得的性能结果。 |
| 比利时 / Leuven | KU Leuven，MICAS 的 Hardware-efficient AI and ML 方向；Marian Verhelst 等 | 多加速器系统、稀疏计算、可变精度、映射与设计空间探索 | [官方方向页](https://micas.esat.kuleuven.be/research/domains/hardware-efficient-ai-and-ml)列出 SNAX、ZigZag/Stream、ZigZag-LLM，以及 2024 年 Stream 论文和 SparseCol 芯片。该方向有多位负责人，不能把 Verhelst 写成整个 MICAS 的唯一负责人。 |
| 荷兰 / Delft | TU Delft，Lab of Efficient Machine Intelligence（EMI）；Chang Gao | 时空稀疏、算法硬件协同、端侧视觉、语音与感知 | [组官网](https://www.tudemi.com/)明确 PI，列出 2025 年动态稀疏工作、2026 年 GrainSpeech 小型语音合成预印本及 BitFair 加速器。论文与预印本状态分别保留，不将接收新闻等同于已发表全文。 |
| 捷克 / Brno | Brno University of Technology，Knowledge Technology Research Group（KNOT）；Pavel Smrž | 低功耗芯片上的模型缩小、嵌入式智能、边缘与云协作 | [官方方向页](https://www.fit.vut.cz/research/group/knot/.en)与[成员页](https://www.fit.vut.cz/research/group/knot/team/.en)确认组名、方向和 principal researcher。**本次仍未核实其 2024–2026 年对应效率方向的具体论文**，作为待进一步筛选的候选。 |

如果 mobileLLM 后续关注端侧语音、传感、稀疏执行和能耗约束，EMI 与 MICAS 的主题关联较直接。TUM AI-Pro、Darmstadt 的工作更偏器件和专用硬件，需要先确认目标硬件是否能承载相应方法。

## 证据边界与下一步使用

12 行去重后对应 9 国。两个 ETH 组只计一个国家；两个 Inria 组是不同团队。上面的官方网页支持团队身份与研究方向，但每行的近期证据并不等价：有的是会议论文，有的是项目、年度报告或预印本，KNOT 的近期具体成果仍缺失。表格不是 SOTA 排名，也没有验证招生名额。

维护者补核修正了国家数、EASL 名称、CORSE 负责人、MICAS 负责人表述、LogiNet 日期和 KNOT 的 PI，并补上 SPCL 的具体论文来源。德国两组来自子代理研究核验员的检索，德国调查员本身未交付有效简报。这些补核不计入应用的自动验收成绩。

当前名单覆盖有限，北欧、爱尔兰、西班牙、葡萄牙及欧洲其他地区尚未系统覆盖；同一国家也远未穷尽。用于选题时，先从最相关的两三个组挑选具体论文，再核对代码、模型规模、硬件条件和基线；用同一设备与模型实际比较延迟、峰值内存、能耗及质量损失，才能判断能否改进 mobileLLM。
