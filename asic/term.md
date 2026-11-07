# RTL-to-GDS-II Terms

## 常見檔案與結果

- `.v`／`.sv`: 可能是 RTL, testbench 或 gate netlist
- `.sdc`: 時脈, I/O timing, exceptions 等 constraints
- `.lib`／Liberty: cell 功能, timing, power 等模型; 單位要讀檔案確認
- `.db`: 依工具可能是編譯後 library 或其他資料庫, 不可只看副檔名判斷
- `.lef`: 製程與 cell／macro 的實體抽象
- DEF — Design Exchange Format／`.def`: 交換設計的 floorplan, instances, pins, nets, routing 等資料, 依階段內容不同
- OpenDB／`.odb`: OpenROAD 使用的設計資料庫; 不同階段存成不同 checkpoint
- `.spef`: 寄生電阻／電容資料, 不包含全部 timing constraints
- SDF — Standard Delay Format／`.sdf`: 交換延遲及 timing checks, 常用於 gate simulation 的 back-annotation
- Back-annotation, 回填: 把外部延遲等資料對應回模擬模型; 需檢查名稱匹配與實際覆蓋率
- VCD — Value Change Dump／`.vcd`: 記錄模擬訊號隨時間變化的波形, 也可供支援的流程取得活動資訊
- SAIF — Switching Activity Interchange Format／`.saif`: 交換一段時間的切換活動統計, 常用於 power estimation
- `.upf`: power intent; 不是 power grid 幾何資料
- `.gds`／`.gdsii`／`.oas`: 實體 layout 交換資料, 不等於 timing／功能驗證報告
- `.rpt`／`.log`／`.json`: 報告, 人可讀執行紀錄及結構化 metrics; 報告意義仍取決於工具與產生階段

## 本專案開源工具

- Yosys: 讀取 RTL, 進行 synthesis 與 netlist 處理
- ABC: 邏輯最佳化／technology mapping 引擎, 可由 Yosys 等流程呼叫
- OpenROAD: floorplan, placement, CTS, routing, 修復與分析等實體設計功能
- OpenSTA: STA 引擎; 也整合於 OpenROAD
- KLayout: layout 檢視, 處理與支援規則 deck 的 DRC／LVS 等功能
- ORFS — OpenROAD Flow Scripts: 串接 synthesis, 實體實作, 報告與 layout 產出的流程腳本; 不等於 OpenROAD 單一執行檔
- Icarus Verilog／`iverilog`／`vvp`: Verilog 編譯與模擬工具
- Verilator: RTL lint 與編譯式模擬工具; 支援範圍／選項依版本而異

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

## 5. DFT 與低功耗設計: 與實作交錯進行

- DFT — Design for Test／Testability, 可測試性設計: 加入結構, 方便製造後控制與觀察內部狀態, 檢出缺陷
    - 比如說測一個 8 slot, 32 bit wide FIFO, 我可以把 FIFO 所有的 DFF 改成 scan DFF, 然後按照某個順序前面 Q 接後面 SI 的方式把 256 個 SDFF 串成 Scan Chain，然後再 assert SE, 用當初串起來的順序打 256 拍把測資塞進去，讓特定位置填入特定的值
- Scan FF／Scan chain, 掃描正反器／掃描鏈: 在 test mode 下將暫存器串接, 便於移入刺激與移出結果
- Scan shift／Capture, 掃描移位／擷取: 前者搬移測試資料; 後者讓電路運作並記錄反應, 兩者 timing mode 不同
- ATPG — Automatic Test Pattern Generation, 自動測試向量產生: 依 fault model 產生製造測試向量, 不是一般 RTL 隨機測資
- Functional mode／Test mode, 功能／測試模式: 不同操作模式會有不同 clocks, case settings 與 timing requirements
- Clock gating, 時脈閘控: 不需更新時停止部分 clock 切換, 降低動態功耗
- ICG — Integrated Clock-Gating cell, 整合式時脈閘控元件: library 提供的 clock-gating cell, 常包含避免 enable glitch 的結構
- Dynamic power／Leakage power, 動態／漏電功耗: 前者主要來自切換與短路電流, 後者在不切換時仍可能存在
- Activity／Toggle rate, 切換活動／切換率: 估計功耗的重要輸入; 無工作負載活動時只能依假設估計
- Power domain, 電源域: 共用某組電源控制／供應規則的邏輯範圍, 不必與 clock domain 一致
- UPF — Unified Power Format: IEEE 1801 的 power intent 表達方式, 描述 power domains, 供應及相關低功耗策略
- MBIST — Memory Built-In Self-Test, 記憶體內建自測: 使用內建控制與演算法測試 memory
- JTAG／IEEE 1149.1: JTAG 原為 Joint Test Action Group 名稱; 相關標準定義 TAP 與 boundary-scan 存取機制
- TAP — Test Access Port, 測試存取埠: 控制／存取 JTAG 測試邏輯的介面及控制結構
- Fault coverage, 故障覆蓋率: 對指定 fault model 能被測試檢出的比例, 不等同 RTL code coverage
- Isolation cell, 隔離元件: 某電源域關閉時, 把其對外輸出固定為安全值
- Level shifter, 電位轉換器: 協助不同供應電壓的電源域傳遞訊號
- Retention cell, 狀態保持元件: 在主要供電關閉時保留必要狀態
- Power gating, 電源閘控: 關閉區域供電以降低漏電, 需配合隔離, 狀態與電源開關規劃
- DVFS — Dynamic Voltage and Frequency Scaling, 動態電壓頻率調整: 以不同電壓與頻率工作點取捨效能與功耗

## 6. Floorplan 與 Power Planning

- Floorplan, 平面規劃: 決定 block 外形, macro, IO 與主要實作空間
- Core, 核心區域: 主要放置標準元件／macros 的區域, 通常與外框保有間距
- Die area／Core area, 外框／核心面積: 不等於合成報告的 cell 面積
- Aspect ratio, 長寬比: 描述形狀; ORFS 的 `CORE_ASPECT_RATIO` 定義為高／寬
- Margin, 邊距: core 與 die 外框之間的距離
- Utilization, 利用率: cell 面積相對可用放置面積的比例, 須確認報告是否扣除 macros／blockages
- Placement density, 放置密度: placer 的目標密度參數, 與決定初始 core 面積的 utilization 不完全相同
- Row／Site, 元件列／放置格點單位: 標準元件需符合 library 指定的排列與對齊規則
- Macro placement, 巨集擺放: 安排 SRAM 等 macro 的位置與方向, 影響走線, 時序與供電
- IO pin placement, 介面 pin 配置: 安排 block 邊界上的訊號接點, 不等於整顆晶片的封裝 pad 配置
- Blockage, 阻擋區: 限制某區域放置或走線; placement blockage 與 routing blockage 用途不同
- PDN／PG — Power Distribution Network／Power-Ground, 供電網: 將電源與接地分配到各元件的導線, via 與相關結構
- Power ring／Stripe／Rail, 電源環／主幹／電源軌: 不同尺度的供電導線, 實際結構依 block 與製程而定
- Halo／Keepout, 保留距離: macro 周圍限制放置等活動的區域, 為 pins, 供電與走線預留空間
- Channel, 通道: macros 或 block 間留給走線／元件的空間
- Partition, 分區: 把大型設計切成可分工與階層實作的區塊, 需管理介面與 timing budget
- Rectilinear floorplan, 直角多邊形規劃: 使用水平／垂直邊的不規則外形, 例如 L 形, 支援程度依工具／流程而異
- Pad ring／Bump, 周邊 pad 環／凸塊: 與外部封裝連接的結構, 和小型 block 的 IO pin 不同
- Tap／Well-tie cell, 井接觸元件: 把 well／substrate 接到適當電位, 滿足製程與可靠度要求
- Endcap cell, 列端元件: 放在 row 邊界以滿足井, implant 等實體規則; 內容依 library 而定
- Tie-high／Tie-low cell, 常數元件: 以 library 允許的方式提供邏輯 1／0, 不是隨意把訊號 pin 直接接到電源

## 7. Placement 與實體最佳化

- Placement, 元件放置: 決定 standard cells 的位置, 以改善 timing, wirelength 與可繞線性
- Global placement, 全域放置: 決定整體分布, 過程中可能仍有重疊或未對齊
- Legalization, 合法化: 消除不合法重疊, 讓 cells 對齊 rows／sites 並符合放置限制
- Detailed placement, 細部放置: 在合法放置附近改善排列與目標指標
- Congestion, 壅塞: 某區域的 routing demand 接近或超過可用 capacity
- Overflow, 溢出量: 估計／全域 routing 中超過可用資源的需求量; 不是最後 DRC 數
- Routability, 可繞線性: 在規則與資源限制下完成連線的難易程度
- Buffer insertion, 插入緩衝器: 分段驅動長線或大負載, 改善 slew／delay, 但增加面積與功耗
- Cell sizing, 元件尺寸調整: 選擇不同驅動能力的等效 cell; 較大通常更強, 但負載與面積也可能上升
- Timing repair, 時序修復: 透過 sizing, buffer, 位置或邏輯調整等方式改善違規
- HPWL — Half-Perimeter Wirelength, 半周長線長估計: 用 net pin bounding box 的寬加高估計線長, 不是實際繞線長度
- Cell padding, 元件間距預留: 在 placement 中增加元件周圍預留空間, 常用於改善 pin access／routing
- VT swap, 臨界電壓元件替換: 改用不同 Vt 的等效 cell, 取捨速度與漏電
- Logic cloning／Replication, 邏輯複製: 複製 driver／邏輯以降低單一分支負載或長距離連線
- Physical synthesis, 實體導向邏輯最佳化: 利用位置與互連資訊調整 netlist, 不只是搬動既有 cells
- Pre-CTS, 時脈樹建立前: 常使用 ideal clock 或預估 latency／uncertainty; 不能直接當作最終 propagated-clock timing

## 8. CTS 與時脈網路

- CTS — Clock Tree Synthesis, 時脈樹合成: 建立 clock 分配網路, 控制延遲, skew, slew 等要求
- Clock source／Sink, 時脈源／負載端: clock 的來源, 以及接收它的 FF, ICG 等 clock pins
- Clock buffer／Inverter, 時脈緩衝／反相器: 用於時脈分配的 library 元件
- Clock latency, 時脈延遲: clock reference 到指定位置的延遲; 需區分 source latency 與 network latency
- Insertion delay, 插入延遲: 在 CTS 情境中通常指 clock root 到 sink 的網路延遲, 定義需對照工具報告
- Skew, 時脈偏斜: 兩個 clock sinks 的 clock arrival 差; 討論正負前需先定義 capture − launch 等符號方向
- Ideal clock, 理想時脈: 不由實際 clock network 傳播計算各段延遲, 可能搭配手動 latency 等假設
- Propagated clock, 傳播時脈: 利用 clock network 的 cell／wire 模型計算 clock arrival
- Post-CTS, 時脈樹建立後: 開始依實作 clock network 檢查 timing, 通常需要處理 hold 與其他修復
- Hold fixing, 保持時間修復: 常以資料路徑加延遲等方法處理過早抵達, 同時需確認不破壞 setup
- Useful skew, 有益偏斜: 刻意調整 clock arrival, 在不同路徑間分配 timing budget; 可能改善 setup 同時惡化 hold
- Clock balancing, 時脈平衡: 讓指定 sink／群組的 clock latency 差異滿足目標, 不必等於所有 sinks 完全同時
- Clock mesh, 時脈網格: 以網格結構分配 clock, 可提高某些變異下的穩健性, 但有功耗及實作代價
- NDR — Non-Default Routing Rule, 非預設繞線規則: 為指定 nets 使用不同線寬／間距等規則, 常見於 clock 或關鍵 nets

## 9. Routing 與寄生萃取

- Routing／P&R／PnR — Place and Route, 繞線／布局繞線: PnR 通常泛指從 floorplan 到放置, CTS, routing 的實體實作工作
- Global routing, 全域繞線: 決定粗略路徑與資源分配, 評估壅塞並提供較實際的互連估計
- Detailed routing, 細部繞線: 決定精確導線與 vias 的位置, 符合幾何設計規則
- Track, 繞線軌道: routing layer 上規劃的導線位置格點
- Metal layer, 金屬層: 例如 M1, M2, 承載訊號與供電連線; 不同顏色常代表不同層
- Via, 跨層導通結構: 連接不同金屬層; 與同層平面交叉不同
- Pin access, pin 可達性: router 能否合法接到 cell／macro 的 pin
- Open／Short, 斷路／短路: 應相連卻未連接, 或不應相連卻接在一起
- Parasitics, 寄生效應／元件: 實際導線帶來的電阻, 電容等效應, 不能把線當作零延遲
- RC — Resistance-Capacitance, 電阻／電容: 影響互連延遲, slew 與耦合
- PEX／RCX — Parasitic／RC Extraction, 寄生／RC 萃取: 從實體幾何與製程模型建立寄生網路
- SPEF — Standard Parasitic Exchange Format: 用於交換 net 寄生電阻／電容等資料, 供 timing／power 工具讀取
- Post-route／Post-layout, 繞線後／版圖後: 常指利用較完整實體資訊分析; 仍需確認使用哪一版 extraction 與 netlist
- Coupling capacitance, 耦合電容: 相鄰導線間的電容, 使其他訊號切換影響本線路
- SI — Signal Integrity, 訊號完整性: 檢查耦合, 雜訊及波形影響等問題
- Crosstalk, 串擾: aggressor 的切換透過耦合影響 victim, 可能改變延遲或產生 noise
- Aggressor／Victim, 干擾源／受干擾線: 串擾分析中的兩種相對角色
- Shielding, 屏蔽: 使用適當參考線等安排降低敏感訊號的耦合影響
- Redundant via, 冗餘 via: 在允許空間加入多個 via, 提高可靠度並可能降低電阻
- Antenna effect, 天線效應: 製程期間導線累積電荷可能損害 gate oxide; 不是無線通訊天線
- Antenna repair, 天線修復: 依規則使用 diode, layer jumper 等方法處理, 取決於 library／PDK 支援
- Metal fill／Dummy fill, 金屬填充: 加入製程要求的金屬圖形以滿足密度等需求; 可能影響寄生值, 需依流程重新分析

## 10. Physical Verification, Signoff 與 Tapeout

- PV — Physical Verification, 實體驗證: 檢查 layout 的幾何, 連接與相關電氣／製程規則
- DRC — Design Rule Checking, 設計規則檢查: 檢查線寬, 間距, 包覆, 密度等幾何規則; 規則集合取決於製程與 deck
- LVS — Layout Versus Schematic, 版圖與電路比對: 從 layout 萃取元件／連接, 與參考 schematic／netlist 比較
- ERC — Electrical Rule Checking, 電氣規則檢查: 檢查浮接, 供電連接等電氣條件; 內容由 deck 與工具決定
- Rule deck, 規則檔: 供 DRC／LVS 等工具執行的檢查規則, 通常與特定製程及版本綁定
- Signoff, 簽核: 依專案與 foundry 規範, 用指定工具／模型／版本完成必要檢查並接受結果
- Timing signoff, 時序簽核: 確認要求的 modes／corners, constraints, 寄生與變異分析均符合時序標準
- IR drop, 供電壓降: 供電網路電阻與電流造成的電位下降; 動態壓降分析也會涉及切換活動及供電網路動態效應
- EM — Electromigration, 電遷移: 電流密度等條件可能造成金屬原子遷移, 影響長期可靠度
- GDS-II／GDSII — Graphic Data System II: 常見 layout 交換格式, 以階層, 幾何圖形及 layer 等表示版圖; GDS 是慣用簡稱
- Stream-out／Stream-in, 版圖匯出／匯入: 輸出或讀入 GDSII／OASIS 等資料, 不代表已通過所有 signoff
- Tapeout, 設計交付製造: 交付符合要求的最終設計資料供後續製造準備; 不等於剛產生一份 GDS
- OASIS — Open Artwork System Interchange Standard: 另一種 layout 交換格式, 通常有較有效率的資料表示／壓縮方式
- DFM — Design for Manufacturability, 可製造性設計: 超越基本合法性, 改善良率與製造穩健性
- Density check, 密度檢查: 確認指定視窗內各類圖形密度符合製程要求
- CMP — Chemical Mechanical Planarization, 化學機械平坦化: 製造中的平坦化處理; layout density 會影響製程結果
- ESD — Electrostatic Discharge, 靜電放電: 需藉保護結構與規則避免靜電損壞, 與一般功能模擬不同
- Latch-up, 閂鎖效應: 寄生結構形成非預期導通, 可能造成大電流, 需依製程要求預防
- Seal ring, 密封／保護環: die 周邊用於製程／機械保護的結構, 與 power ring 不同
- Scribe line／Dicing street, 切割道: die 之間供切割與部分製程用途使用的區域
- Mask／Reticle, 光罩: 承載曝光圖案的製造資料／實體載具, 與 wafer 或單顆 die 不同
- OPC — Optical Proximity Correction, 光學鄰近修正: 修正光罩圖形以補償曝光／製程效應, 不是一般 RTL designer 手工進行的工作
- Waiver, 豁免: 某項違規在有理由與審核紀錄下被接受; 不是關閉訊息就當作通過

注意: router DRC = 0, KLayout DRC = 0, LVS clean 與 timing clean 是不同結論

## 11. others

### 工程變更與交付管理

- ECO — Engineering Change Order, 工程變更: 受管理的局部修改, 可能改功能, 也可能只改善 timing／實體問題
- Functional ECO, 功能變更: 修改設計邏輯行為, 需對照更新後的 reference 驗證
- Timing ECO, 時序變更: 以保持功能為前提改善 timing, 例如 buffer／cell sizing
- Pre-mask／Post-mask ECO, 光罩製作前／後變更: 依製造進度受到不同成本與可改層別限制
- Metal-only ECO, 僅金屬層變更: 利用既有 cells 或 spare cells 等, 以受限金屬層改動完成修改; 仍需驗證可行性
- Spare cell, 備用元件: 預先放置以支援後續 ECO 的元件
- Incremental run, 增量執行: 重用部分既有結果, 只重做受影響階段; 必須管理輸入與依賴關係
- Deliverables／Handoff, 交付物／交接: 傳給下一團隊的 RTL, netlist, constraints, 模型, 報告與版本紀錄等
- Baseline, 基準版本: 用於後續比較的固定輸入, 設定及結果
- Correlation, 結果相關性: 比較不同階段／工具的分析是否一致, 並解釋差異來源
- Abstract／Timing model, 抽象／時序模型: 以較小表示提供 block 的介面, 實體或 timing 資訊, 供階層整合使用
- ETM — Extracted Timing Model, 萃取時序模型: 將 block 重要的邊界 timing 行為以較小模型表示, 供上層分析
- ILM — Interface Logic Model, 介面邏輯模型: 保留與介面相關的部分邏輯, 用於階層時序分析; 細節依工具定義
- Re-spin, 重新投片: 修正版設計再次製造, 涉及成本與時程; 不是單純重跑工具

### JD／業界常見商用工具

- Synopsys
    - DC — Design Compiler: RTL synthesis
    - PT — PrimeTime: signoff STA 與相關時序分析
    - Formality: formal equivalence checking; 不是一般 pattern simulator
    - ICC2 — IC Compiler II: 數位實體實作／PnR
    - Fusion Compiler: 整合邏輯與實體實作的工具平台
- Cadence
    - RC - RTL Compiler: JD 中 RC compiler 通常指此 synthesis 工具
    - Genus: RTL synthesis 工具, Cadence RTL Compiler 的下一代
    - Conformal: 常見 equivalence checking 工具; 口語 LEC 也可能指它或其工作流程
    - Innovus: 數位實體實作／PnR
    - Tempus: signoff STA
- Calibre, Siemens EDA: physical verification／extraction 等工具系列; 具體功能由產品模組決定
- VCS／Xcelium／Questa: 不同廠商的模擬工具／平台名稱, 不是 synthesis 或 STA 工具

### 業界職稱與工作分工-設計與驗證

- RTL／Logic Design Engineer, 邏輯設計工程師: 微架構, RTL, 功能除錯, 並配合 timing／power／area 改善
- Microarchitecture Engineer, 微架構工程師: 定義 pipelines, 資料路徑, 資源與控制等設計方案
- DV — Design Verification Engineer, 設計驗證工程師: testbench, reference model, assertions, coverage 與功能回歸
- Formal Verification Engineer, 形式驗證工程師: 依團隊執行 equivalence Checking 或 property verification, 兩者能力需求有重疊但不完全相同
    - Equivalence Checking Engineer, 等價性檢查工程師: 檢查「同一個電路的兩個不同版本」在功能上是否完全一模一樣
    - Property Verification Engineer, 屬性驗證工程師: 使用 SVA 或 PSL 等語言，將晶片的規格轉換為數學邏輯上的屬性，並利用形式驗證工具確保電路符合規格，在任何極端情況下（Corner Cases）都不會出錯（如 Deadlock 或功能違規）
- DFT Engineer, 可測試性設計工程師: scan, ATPG, BIST, test modes 與測試覆蓋率
- FPGA Engineer: FPGA RTL, IP 整合, implementation, 板級驗證等; 和 ASIC PD 有部分可轉移基礎, 但流程不同

### 業界職稱與工作分工-實作與簽核

- ASIC Implementation Engineer, ASIC 實作工程師: 可能涵蓋 synthesis, constraints, equivalence, 實體實作與 timing closure
- Synthesis Engineer, 合成工程師: RTL／library／constraints 管理, mapping, QoR 最佳化與 netlist 交付
- PD — Physical Design Engineer, 實體設計工程師: 可能從 netlist 到 layout, 也可能從 RTL freeze 起負責更廣的 implementation 工作
- P&R／PR／APR Engineer, 布局繞線工程師: APR 常指 Automatic Place and Route; 負責 floorplan, placement, CTS, routing 與實體 timing 修復
- STA／Timing Engineer, 時序工程師: constraints, timing model, MCMM, 時序分析／closure／signoff 與跨團隊問題追查
- Chip Integration Engineer, 晶片整合工程師: 整合 IP／partitions, 介面, netlist, 供電／時脈與 top-level 分析
- Physical Verification Engineer, 實體驗證工程師: DRC, LVS, ERC, 相關實體規則及 signoff 問題處理
- Power Integrity Engineer, 電源完整性工程師: PDN, IR drop, EM 與供電可靠度分析
- CAD／Methodology／Flow Engineer, 設計工具／方法學工程師: 工具導入, 流程自動化, 版本管理, 報告整合與方法改善此處 CAD 是 Computer-Aided Design
- Library／Characterization Engineer, 元件庫／特性化工程師: 建立, 驗證與維護 library 模型及相關品質
- Custom Layout Engineer, 客製化版圖工程師: 電晶體層級或客製化電路 layout, 不完全等同數位 APR

### 業界職稱與工作分工-協作角色

- AE — Application Engineer, 應用工程師: 工具／IP 廠商協助客戶導入, 除錯與方法學支援
- FAE — Field Application Engineer, 現場應用工程師: 面向客戶的技術支援角色, 工作範圍依公司而異
- Silicon Validation Engineer, 晶片驗證工程師: 在回片後的實際晶片上測試, 量測與除錯, 與 pre-silicon DV 不同
- Product／Test Engineer, 產品／測試工程師: 量產測試, 良率, 失效分析及測試成本等, 分工依組織而定
- RDSS — Research and Development Substitute Services, 研發替代役: 招募／服役身分類型, 不是某個 EDA 階段或獨立技術職能

### reference

- [ORFS Flow Tutorial](https://openroad-flow-scripts.readthedocs.io/en/latest/tutorials/FlowTutorial.html): RTL-to-GDS-II 階段與操作入口
- [ORFS Flow Variables](https://openroad-flow-scripts.readthedocs.io/en/latest/user/FlowVariables.html): 本練習設定的意義
- [OpenROAD 文件](https://openroad.readthedocs.io/en/latest/): floorplan, placement, CTS, routing, extraction 等模組
- [OpenSTA 原始碼與文件](https://github.com/The-OpenROAD-Project/OpenSTA): STA, SDC 與報告指令
- [Synopsys STA 說明](https://www.synopsys.com/glossary/what-is-static-timing-analysis.html): STA 概念與分析目的
- [Synopsys Equivalence Checking 說明](https://www.synopsys.com/glossary/what-is-equivalence-checking.html): 功能等價性驗證
- [Synopsys DFT 說明](https://www.synopsys.com/glossary/what-is-design-for-test.html): 製造測試與 DFT
- [Cadence Physical Verification／Extraction 說明](https://community.cadence.com/cadence_blogs_8/b/cic/posts/custom-ic-design-flow-methodology-circuit-physical-verification-and-parasitic-extraction): DRC／LVS 與寄生萃取的分工