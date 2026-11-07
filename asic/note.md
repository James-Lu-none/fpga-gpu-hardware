# ORFS RTL-to-GDS-II note

## 1. Synthesis: 邏輯合成

```sh
make -C asic flow STAGE=synth
```

Input:

- `rtl/sm/sp/unit/alu_int32_mul.sv`: 描述乘法功能與兩級 pipeline 的 RTL
- `asic/mul32/constraints/mul32.sdc`: clock, I/O delay, uncertainty, driver／load 等約束
- Nangate45 `*.lib`: 可用 standard cells 的邏輯功能, 時序與功耗模型
- 平台 `*.lef` 與 `asic/mul32/config.mk`: 建立後續 OpenROAD database 所需的實體抽象與流程設定

Process:

- 展開 RTL hierarchy／parameters，辨識組合邏輯與暫存器
- 最佳化邏輯，將運算與暫存器映射成 library 中的 standard cells
- 建立 mapped netlist，並轉成 OpenROAD database，供後續實體設計使用
- 此階段沒有完成 placement／routing，互連延遲仍需依模型估計

Output:

- `results/1_2_yosys.v`: 映射到 standard cells 的 Verilog netlist
- `results/1_synth.odb`: 合成後的 OpenROAD 設計資料庫
- `results/1_synth.sdc`: 供後續階段使用的時序約束
- `reports/synth_stat.txt`: cell 種類, 數量與面積等統計
- `logs/1_*.log`: 合成與 database 建立紀錄; 檢查 unresolved modules, latches, unmapped cells 等問題

## 2. Gate simulation: 合成後功能模擬

```sh
make -C asic gate-test
```

Input:

- `results/1_2_yosys.v`: 已完成 synthesis 的 netlist; 本 target 不會自動執行 synthesis
- Nangate45 `*.lib`: 由 Yosys 產生 standard-cell 的 Verilog 功能模型
- `sim/unit/mul32/tb_mul32.sv`: clock, DUT 連接與 timeout
- `sim/unit/mul32/mul32_pattern.sv`: 測試資料, golden model 與 pipeline latency 檢查

Process:

- 將 Liberty 中可描述的 Boolean／sequential 功能轉成模擬模型
- 用 Icarus Verilog 編譯 mapped netlist, cell models 與共用 testbench
- 執行邊界值, walking bits 與隨機測試，比較 DUT 輸出和參考乘積
- 本 target 是零延遲功能模擬，沒有讀取 SDF，不檢查實際 setup／hold，也不是 formal equivalence

Output:

- `artifacts/asic/sim/nangate45.v`: 產生的 cell 功能模型
- `artifacts/asic/sim/gate`: 供 `vvp` 執行的模擬檔

## 3. Floorplan: 平面與供電規劃

```sh
make -C asic flow STAGE=floorplan
```

Input:

- `results/1_synth.odb`, `results/1_synth.sdc`: 合成後設計與約束
- 平台 `*.lef`／`*.lib`: routing layers, sites, cell 尺寸, pins 與時序模型
- `asic/mul32/config.mk`: 目前 core utilization 35%，未另外指定 aspect ratio
- 平台的 tapcell, PDN 等設定: 定義邊界元件與供電網路的建立方式

Process:

- 依 cell 面積, 目標 utilization, 長寬比與 margin 決定 die／core 範圍
- 建立 standard-cell rows，配置 block IO pins
- 加入平台要求的 tap／邊界元件，建立 VDD／VSS power grid
- 本例只有 standard cells，沒有 SRAM macros，也沒有完整晶片的 IO pad ring

Output:

- `results/2_floorplan.odb`: 包含 core, rows, pins 與 power grid 的 database
- `results/2_floorplan.sdc`: 此階段使用的時序約束
- `reports/2_*.rpt`, `logs/2_*.log`: floorplan 子步驟的分析與執行紀錄
- 可用 `make -C asic gui GUI_TARGET=gui_floorplan` 檢查邊界, rows, IO pins 與供電網

## 4. Placement: 標準元件放置

```sh
make -C asic flow STAGE=place
```

Input:

- `results/2_floorplan.odb`, `results/2_floorplan.sdc`: 已規劃的實體空間與約束
- 平台 cell models, 實體規則與互連 RC 估計設定
- `asic/mul32/config.mk`: 目前 `PLACE_DENSITY = 0.55`，控制 placer 的目標密度

Process:

- Global placement: 決定 cells 的整體分布，兼顧線長, timing 與 congestion
- Legalization／detailed placement: 消除非法重疊，對齊 rows／sites，細調位置
- 視流程需要進行 buffer insertion, cell sizing 等最佳化
- 此時仍未完成 clock tree 與詳細繞線，timing 使用當前階段的估計

Output:

- `results/3_place.odb`: 已完成 placement 的 database
- `results/3_place.sdc`: 此階段使用的時序約束
- `reports/3_*.rpt`, `logs/3_*.log`: placement, timing, 面積與相關最佳化紀錄
- 重點查看合法放置, congestion／overflow, setup slack，以及 cell／buffer 面積變化

## 5. CTS: 時脈樹合成

```sh
make -C asic flow STAGE=cts
```

Input:

- `results/3_place.odb`, `results/3_place.sdc`: 已放置設計與 clock 定義
- Library 的 clock buffers／inverters，以及平台 clock routing／RC 等設定

Process:

- 找出 clock source 與 clock sinks，建立 clock 分配網路
- 插入並放置 clock cells，控制 clock slew, latency 與 skew
- 分析實作後 clock network 對 setup／hold 的影響，依流程設定進行修復
- Post-CTS 的 propagated-clock timing 比 pre-CTS ideal-clock 分析更接近實作，但仍未完成詳細 routing

Output:

- `results/4_cts.odb`: 含 clock tree 的 database
- `results/4_cts.sdc`: CTS 後供後續使用的時序約束
- `reports/4_cts_final.rpt`: CTS 後的 timing 報告
- `logs/4_*.log`: clock tree 建立與修復紀錄; 查看 sinks, clock cells, skew／latency 與 setup／hold

## 6. Routing: 繞線

```sh
make -C asic flow STAGE=route
```

Input:

- `results/4_cts.odb`, `results/4_cts.sdc`: 包含 clock tree 的已放置設計
- 平台 routing layers, tracks, vias, 幾何規則與 RC 模型

Process:

- Global routing: 規劃各 net 的大致路徑與使用資源，分析 congestion
- Detailed routing: 決定實際金屬與 via 幾何位置，修復 router 能檢查的違規
- 依此平台流程插入 filler cells，完成 route 階段的 database
- Router DRC 與後面的 KLayout GDS DRC 使用的檢查範圍不同，不能互相取代

Output:

- `results/5_route.odb`: 完成 routing 的 database
- `results/5_route.sdc`: routing 後供後續使用的約束
- `reports/5_*.rpt`, `logs/5_*.log`: routing, timing, 壅塞, router DRC／antenna 等紀錄，依子步驟而異
- `route` 不等於完成 final GDS／SPEF; 進入以下 final checks 前，先執行 finishing

## 7. Finishing: 最終資料產出

```sh
make -C asic flow STAGE=finish
```

`flow` 必須明確指定 `STAGE`；省略或留空會報錯，不執行工具。

Input:

- `results/5_route.odb`, `results/5_route.sdc`: routing 結果
- 平台寄生萃取規則, GDS layer mapping, cell GDS 與 finishing 設定

Process:

- 執行平台設定的 finishing／fill 步驟
- 從實際 routing 萃取寄生 RC，產生 SPEF 並進行 final timing／power 等分析
- 匯出 DEF, Verilog, SDC, ODB 與 GDS; GDS 需合併對應的 cell 版圖

Output:

- `results/6_final.{odb,def,v,sdc,gds,spef}`: 後續檢查使用的最終設計資料
- `reports/6_finish.rpt`: final timing 等分析報告
- `logs/6_report.log`, `logs/6_report.json`: final 執行紀錄與數值 metrics

## 8. Signoff: 四項最終檢查

```sh
make -C asic signoff
```

先執行 `make -C asic flow STAGE=finish` 產生完整 final 資料。
`signoff` 使用 ORFS 原生 `finish` 一起產生 STA／static IR 分析，再依序執行 DRC、LVS。
缺少 final 檔案時直接停止。每次移除舊的 final report 與 DRC／LVS database，確保重新分析。
即使使用 `make -j`，三個執行階段仍依序完成；任一命令失敗就停止。原生 Make 若發現上游輸入較新，仍可能重建相依產物。
此處 signoff 是本專案的檢查入口名稱，不代表 foundry-qualified signoff。

### 8.1 STA: 最終靜態時序檢查

Input:

- ORFS finishing 階段的 routed／filled database 與 SDC。
- Nangate45 typical `*.lib`、平台 RC 設定與 OpenRCX 萃取規則。
- 原生流程由 routed 幾何重新萃取並載入 `results/6_final.spef`，計算 final timing。

Process:

- 由 ORFS 內建 `final_report.tcl`／`final_outputs.tcl` 執行，不需要專案自訂 `verify.tcl`。
- 利用實作 clock network 與 extracted parasitics 計算 setup／hold 路徑、worst slack、TNS 等。
- 輸出 slew、capacitance、fanout 等限制的檢查與各類 metrics。
- 與 static IR 在同一次原生 final analysis 中產生結果，不是兩個獨立執行的 target。

Output:

- `reports/6_finish.rpt`: final setup／hold 路徑與時序分析報告。
- `logs/6_report.log`: 原生 final analysis 的執行紀錄。
- `logs/6_report.json`: setup／hold slack、TNS 等結構化 metrics。
- 目前僅 typical corner；命令成功仍需審閱約束、分析覆蓋範圍與 violations，不能只看 exit code 判定 timing clean。

### 8.2 DRC: 版圖幾何規則檢查

Input:

- `results/6_final.gds`: 最終幾何版圖
- 平台 `drc/FreePDK45.lydrc`: KLayout DRC deck，定義需執行的幾何檢查

Process:

- 檢查 deck 定義的線寬, 間距, 包覆, 密度等規則，實際範圍以 deck 為準
- 將違規位置與類型寫入 report database
- 透過 ORFS 的 KLayout DRC target 檢查 final GDS；signoff 先移除舊報告，確保重新檢查

Output:

- `reports/6_drc.lyrdb`: DRC report database，可在 KLayout 查看違規位置
- `reports/6_drc_count.rpt`: ORFS 依 report 計算的違規筆數
- `logs/6_drc.log`: 執行紀錄
- 本入口檢查違規數，非 0 即回傳失敗；DRC 不驗證電路功能或等價性

### 8.3 LVS: 版圖與參考電路比對

Input:

- `results/6_final.gds`: 最終幾何版圖
- `results/6_final.v`: 用來產生 top-level CDL 的最終 netlist
- 平台 `NangateOpenCellLibrary.cdl`: standard cells 的電晶體級參考電路
- `asic/lvs/lvs_freepdk45.lylvs`: 本 repo 的 KLayout LVS deck，定義層別, 元件萃取, 連接與比對規則
- `*.cir`／`*.sp` 也常用於 SPICE 參考網表，但副檔名不保證內容格式本指令實際使用 CDL; 不需要 `.lydrc`

Process:

- ORFS 將 final Verilog 轉成 `6_final.cdl`，再附上 standard-cell CDL，形成完整 reference
- Deck 從 GDS 萃取電晶體與連線，建立 extracted netlist
- 比對 layout 與 reference 的電路連接及設定要求的元件參數，例如 W／L
- Signoff 每次都重新執行 LVS 比對；失配會回傳失敗

Output:

- `results/6_final.cdl`: 由 final netlist 產生的 top-level CDL
- `objects/6_final_concat.cdl`: 附上 cell 電晶體級定義的參考網表
- `results/6_lvs.lvsdb`: LVS 比對資料庫，可查看匹配, 失配與對應的版圖位置
- `results/6_lvs_extracted.cir`: 從版圖萃取的電路網表
- `logs/6_lvs.log`: 執行紀錄與比對結果

本 deck 對 Nangate cells 使用隱含 well／supply 連接，包含 `PWELL` 接 `VSS` 的假設
比對成功不等於已證明實際 well taps 正確來源與修改見 [lvs/SOURCE.md](lvs/SOURCE.md)

### 8.4 IR: 靜態供電壓降分析

Input:

- 原生 final analysis 載入的實體 database，包含 power grid 幾何、cells 與連接資訊。
- Typical `*.lib` 與平台 RC 設定: cell 功耗與供電網路分析所需模型。
- Nangate45 平台 `config.mk` 的 `PWR_NETS_VOLTAGES`／`GND_NETS_VOLTAGES`: VDD 1.1 V、VSS 0 V。
- 使用 ORFS／工具預設活動與供電來源設定；訊號 SPEF 本身不是完整 PDN 模型。

Process:

- ORFS 內建 `final_outputs.tcl` 在寄生萃取後呼叫 `analyze_power_grid`。
- 依 cell 功耗估計與供電網路模型執行 static IR-drop 分析，同時輸出供電連通性相關訊息。
- 分別分析 VDD 壓降與 VSS 電位上升；不是使用真實 workload 的 dynamic IR 分析。
- 這是前述原生 `finish` 已執行的部分，文件在此分項解釋，不會另外再跑一次。

Output:

- `logs/6_report.log`: IR report，包括供應電壓、平均與最差壓降等。
- `reports/VDD.rpt`、`reports/VSS.rpt`: 各供電網的錯誤紀錄，不是逐 cell 電壓表。
- 目前未提供實際 workload activity、封裝模型或 IR 驗收門檻，需依預設假設解讀數值。

## 參考資料

- [LVS deck 來源與本地修改](lvs/SOURCE.md)
- [ORFS tutorial](https://openroad-flow-scripts.readthedocs.io/en/latest/tutorials/FlowTutorial.html)
- [ORFS variables](https://openroad-flow-scripts.readthedocs.io/en/latest/user/FlowVariables.html)
- [Nangate45 platform](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts/tree/master/flow/platforms/nangate45)
- [OpenSTA](https://github.com/The-OpenROAD-Project/OpenSTA)
