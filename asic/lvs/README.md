# FreePDK45 LVS source snapshot

- Accept ORFS `in_gds`, `top_cell`, `cdl_file` and `report_file` arguments.
- Use `report_lvs` to write the comparison database and save the extracted
  netlist beside it; retain the original interactive input fallbacks.
- Deck 加入了 BULK／PWELL／VSS 的虛擬連接規則，讓從 GDS 萃取出的電路符合 CDL 的 well 接地假設，因此 LVS 通過只能證明這個假設下的電路匹配，不能證明實際 well-tap 一定沒有缺陷