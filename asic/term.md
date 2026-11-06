# RTL-to-GDS-II Terms

## 1. RTL 與功能驗證

- Assertion／SVA — SystemVerilog Assertions: 以性質描述預期行為, 可用於模擬或 formal property verification
- Coverage, 覆蓋率: 衡量測試觸及的程式, 功能或性質範圍; 高覆蓋率仍不保證沒有 bug
- CDC — Clock Domain Crossing, 跨時脈域: 資料跨越不同或非同步時脈域的情況, 需處理 metastability 與資料一致性
- RDC — Reset Domain Crossing, 跨重置域: 不同 reset 控制的暫存器之間可能因 reset 行為產生問題
- RTL freeze, RTL 凍結: 某個里程碑後限制 RTL 改動, 後續修改通常要經過 ECO／變更管理

## 2. 製程, library 與設計輸入

- PDK — Process Design Kit, 製程設計套件: 描述特定製程的模型, 層別, 設計規則及相關檔案; 內容依製程而異
- Standard cell, 標準元件: 符合 library 規格的邏輯／儲存元件, 例如 NAND, MUX, DFF
- Liberty／`.lib`: 描述 cell 邏輯功能, timing arc, 功耗, pin 電容及分析條件等資訊的 library 格式
- Timing arc, 時序弧: cell 內輸入與輸出間的延遲關係, 或 pin 間的 setup／hold 等檢查關係
- LEF — Library Exchange Format: 提供 placement／routing 所需的層別, 尺寸, pin, 障礙物等抽象資訊
- Technology LEF, 製程 LEF: 主要描述 routing layer, via, site 等製程相關抽象
- Cell／Macro LEF, 元件 LEF: 描述每個 cell／macro 的外形, pins 與 routing obstruction, 不是完整電晶體版圖
- Macro, 巨集區塊: 較大的預先設計區塊, 常見如 SRAM; hard macro 有固定實體實作
- IP — Intellectual Property, 矽智財: 可重用的設計; 可能以 RTL, netlist 或固定實體 macro 等形式交付
- PPA — Power, Performance, Area, 功耗, 效能, 面積: 實作的主要取捨; 改善其中一項可能犧牲另一項
- PVT — Process, Voltage, Temperature, 製程, 電壓, 溫度: 影響元件速度, 功耗及可靠度的分析條件
- Corner, 分析角落: 一組製程／電壓／溫度或互連條件
    - 最快工作點 (Best-case Corner): FF (製程最快) + 最高電壓 + 最低溫度 -> Hold time violation check
    - 最慢工作點 (Worst-case Corner): SS (製程最慢) + 最低電壓 + 最高溫度 -> Setup time violation check
- TT／SS／FF — Typical-Typical／Slow-Slow／Fast-Fast: 常見電晶體製程角命名, NMOS letter first, PMOS letter second
- RC corner, 互連角落: 描述金屬與介電層變異造成的電阻／電容條件
- Characterization, 元件特性化: 在不同輸入 slew, 輸出 load 與條件下建立 cell 時序／功耗模型
- LVT／SVT／HVT — Low／Standard／High Vt: 一般而言低 Vt 較快但漏電較高, 需依實際 library 判斷
- NLDM — Nonlinear Delay Model, 非線性延遲模型: 常用查表方式, 以輸入轉換時間與輸出負載等估計延遲
- CCS — Composite Current Source: 以電流源等方式表達 cell 行為的模型, 用於更精細的時序／雜訊分析
- Soft IP／Hard IP: 前者通常以可重新實作的 RTL 等形式提供; 後者有固定的實體實作與製程條件

## 3. Synthesis 與等價性驗證

- Synthesis, 邏輯合成: 將 RTL 轉換並最佳化為目標 library 的 netlist
- Elaboration, 展開: 解析 hierarchy, parameter, generate 與連接, 建立具體設計結構
- Net／Pin／Port: net 是連接網路; pin 是 instance 的接點; port 是目前設計層級的介面
- Netlist, 網表: 描述元件及其連接的設計表示; 可能是尚未 mapping 的邏輯, 也可能是標準元件網表
- Technology mapping, 技術映射: 把通用邏輯轉成指定 library 內可用的 cells
- Timing-driven synthesis, 時序導向合成: 依 timing constraints 選擇邏輯結構, cell 與最佳化策略
- Area report, 面積報告: 列出 cell 面積等資訊; cell 面積總和不等於 die 面積
- QoR — Quality of Results, 結果品質: 以 timing, area, power, congestion 等指標評估實作成果
- LEC — Logic Equivalence Checking, 邏輯等價性檢查: 比較兩個設計表示是否滿足指定的功能等價關係
- Reference／Golden 與 Implementation／Revised: 等價性比較中的參考版本與被驗證版本
- GLS — Gate-Level Simulation, 閘級模擬: 使用 netlist 模擬; 可分零延遲與加上 SDF 延遲的模擬
- Formal verification, 形式驗證: 用數學方法證明或反駁性質; 既可指 equivalence checking, 也可指 property checking
- Flatten／Ungroup, 階層攤平: 移除部分設計階層, 可能利於跨階層最佳化, 但會影響名稱與除錯方式
- Retiming, 暫存器重定時: 在符合等價性要求下移動暫存器邊界, 重新分配組合延遲
- Resource sharing, 資源共用: 讓不同運算在適當條件下共用硬體, 以面積換取控制或時序代價
- Physical-aware synthesis, 考慮實體資訊的合成: 利用位置, 互連等估計改善合成與後續 layout 的相關性
- Match point／Compare point, 匹配／比較點: 等價工具對應兩個設計並進行證明的位置
- Counterexample, 反例: 展示被檢查性質或等價關係不成立的輸入／狀態軌跡
- Inconclusive／Unproven, 未完成證明: 不等於已找到功能錯誤, 也不等於通過
- CEC／SEC — Combinational／Sequential Equivalence Checking: 分別著重組合邏輯等價與跨時序狀態的等價關係

## 4. SDC 與 STA: 跨流程反覆分析
 
- SDC — Synopsys Design Constraints: 描述 clocks, I/O timing, exceptions 及部分電氣限制的 Tcl 指令格式
- STA — Static Timing Analysis, 靜態時序分析: 依 timing graph, library, constraints 與互連模型檢查時序, 不需逐筆輸入測資
- Launch／Capture, 發送／接收: 資料由哪個時脈事件發送, 以及由哪個事件接收
- Clock-to-Q／Tcq: FF 的有效 clock edge 到 Q 輸出改變的延遲
- Arrival time, 抵達時間: 依選定 launch event 與路徑模型計算, 資料抵達分析點的時間
- Required time, 要求時間: 依 capture event 和約束, 資料最晚或最早應滿足的時間界線
- Slack, 時序裕量: setup 常為 required − arrival; hold 常為 arrival − required負值表示該檢查違反要求
- WNS — Worst Negative Slack, 最差負裕量: 最嚴重的負 slack; 工具可能在無 violation 時顯示 0, 需與 worst slack 區分
- TNS — Total Negative Slack, 總負裕量: 依工具定義加總違規 endpoint／path group 的負 slack, 通常不是所有可能路徑的直接總和
- Timing budget, 時序預算: 把可用時間分配給外部介面, 各 block 與互連
- Unconstrained endpoint, 未受約束的終點: 缺少適當 timing 定義, 可能讓 "沒有 violation" 變成沒有真正檢查
- Slew／Transition time, 轉換時間: 訊號由低到高或高到低的邊緣快慢, 與 propagation delay 不同
- Timing DRV — Design Rule Violation: 此處指 max transition, max capacitance, max fanout 等電氣／設計限制違反, 不是金屬幾何 DRC
- Path group, 路徑群組: 依 clock 或路徑種類分組, 以便報告與最佳化
- False path, 假路徑: 依設計功能不需執行指定 timing 檢查的路徑; 設定前必須有功能依據
- Multicycle path, 多週期路徑: 描述功能上允許跨多個週期的取樣關係, 需同時確認 setup／hold edge 設定
- Clock uncertainty, 時脈不確定度: 保留給 jitter, skew 預算及其他分析裕量的約束, 需避免與已建模項目重複計入
- Recovery／Removal, 恢復／移除檢查: 非同步 reset／set 解除時, 相對 clock edge 的時序要求
- Recovery check, 恢復檢查: 檢查非同步 reset／set 訊號解除時間是否離下一個 "時鐘有效沿" 太近 (給邏輯電路脫離 reset/set 的時間不夠不夠)
- Removal check, 去除檢查: 檢查非同步 reset／set 訊號解除後, 在時鐘沿 "之後" 維持穩定的時間夠不夠，有沒有太快發生第二次變動或太早撤銷
- Async Reset, Sync Release: 業界 reset 訊號正確做法 reset active 時所有電路瞬間不管時鐘進入 reset 狀態，reset deassert 時經過數層 FF 後同步解除所有電路 reset 狀態
- Minimum pulse width, 最小脈衝寬度: clock 或控制訊號的高／低脈衝需滿足 library 要求
- Clock gating check, 時脈閘控檢查: 確保 enable 切換不會在 gated clock 造成不合法脈衝
- MCMM／MMMC — Multi-Corner Multi-Mode／Multi-Mode Multi-Corner: 同時管理多組 operating mode 與 corner 的分析／最佳化 (讓電路在收斂時同時滿足不同工作環境下的時序驗證)
- OCV — On-Chip Variation, (傳統作法) 晶片內變異: 模型化同一晶片上不同路徑元件的變異
    OCV, AOCV, POCV 中，最保守的是 OCV, 相對來說 POCV 能減少大量的 false Timing Violation
    - OCV Derate, 延遲調整係數: 例如將 nominal delay 乘上 early／late 係數, 模擬製程變異下較快／較慢的情況; 不同模型可能依 cell, net 或其他條件設定
    - AOCV — Advanced OCV: 依路徑深度, 距離等條件提供較細緻的變異模型 (路徑越長, 隨機變異越容易互相抵消; 距離越遠, 局部變異越大, 所以它的 Derate 10%，而是工具會去查一張二維表格)
    - POCV — Parametric OCV: 以參數化統計變異描述 timing, 而非只用單一固定比例 (把每個元件的延遲看作一個高斯常態分佈)
- CPPR／CRPR — Common Path Pessimism Removal／Clock Reconvergence Pessimism Removal: 修正共用 clock path 被分別套用 early／late 延遲後, 額外算出的保守誤差, 這個誤差如果考慮 CPPR, 會依 Derate 係數補償被套用不同延遲的共用 clock path, ex: derate=10%, common clock path delay 0.1ns -> CPPR value = 0.1*(1.1 - 0.9) =  0.02ns
- GBA／PBA — Graph-Based／Path-Based Analysis: GBA 在 timing graph 上傳播並合併各分支的最差條件; PBA 針對特定完整路徑重新分析, 能避免部分不會在該路徑同時出現的最差條件組合, 結果可能較不保守, 但計算成本較高
    常用步驟:
    1. 晶片全跑 GBA 模式 (速度極快, 比較保守)
    2. 挑出 GBA 報出來有違規 (Violation) 的前 10,000 條路徑
    3. 針對這萬條路徑精確切換為 PBA 模式重新計算 (精準還原, 速度慢, 對特定完整路徑檢查時序, 所以比較不保守)
    4. 發現其中 8,000 條路徑在 PBA 下其實都合格了
    5. 只需要動手修剩下真正有問題的 2,000 條路徑
- Temperature inversion, 溫度反轉: 某些製程／電壓條件下低溫可能更慢

