USE [MyInventory]
GO

-- ============================================================
-- Seed: Resource Error Codes สำหรับ Stored Procedures
-- Generated : 2026-06-10
-- Sources   : usp_inventory_putaway
--             usp_inventory_adjustment
--             usp_inventory_adjustment_new_stock
--             usp_inbound_receipt
--             usp_inbound_blind_receipt
--             usp_inbound_close_receipt
--             usp_inbound_close_order
--             usp_count_reconcile
--             usp_mobile_inbound_binding_location
-- ============================================================

-- ── SUCCESS ────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'SAVE_SUCCESS'
    ,@v_vch_resource_en    = 'Success.'
    ,@v_vch_resource_tH    = N'สำเร็จ'
    ,@v_vch_schema         = 'inv';
GO

-- ── ITEM ───────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_ITEM_REQUIRED'
    ,@v_vch_resource_en    = 'Item number is required.'
    ,@v_vch_resource_tH    = N'กรุณาระบุรหัสสินค้า'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_ITEM_NOT_FOUND'
    ,@v_vch_resource_en    = 'Item not found.'
    ,@v_vch_resource_tH    = N'ไม่พบรหัสสินค้าในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_ITEM_NOT_IN_ORDER'
    ,@v_vch_resource_en    = 'Item not found in this inbound order.'
    ,@v_vch_resource_tH    = N'ไม่พบสินค้านี้ในใบรับสินค้า'
    ,@v_vch_schema         = 'inv';
GO

-- ── LOCATION ───────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_LOCATION_REQUIRED'
    ,@v_vch_resource_en    = 'Location is required.'
    ,@v_vch_resource_tH    = N'กรุณาระบุ Location'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_LOCATION_NOT_FOUND'
    ,@v_vch_resource_en    = 'Location not found.'
    ,@v_vch_resource_tH    = N'ไม่พบ Location ในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SAME_LOCATION'
    ,@v_vch_resource_en    = 'Source and target location are the same.'
    ,@v_vch_resource_tH    = N'Location ต้นทางและปลายทางเป็น Location เดียวกัน'
    ,@v_vch_schema         = 'inv';
GO

-- ── WAREHOUSE / OWNER ──────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_WAREHOUSE_NOT_FOUND'
    ,@v_vch_resource_en    = 'Warehouse not found.'
    ,@v_vch_resource_tH    = N'ไม่พบ Warehouse ในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_OWNER_NOT_FOUND'
    ,@v_vch_resource_en    = 'Owner not found.'
    ,@v_vch_resource_tH    = N'ไม่พบ Owner ในระบบ'
    ,@v_vch_schema         = 'inv';
GO

-- ── INVENTORY ──────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INVENTORY_NOT_FOUND'
    ,@v_vch_resource_en    = 'Inventory not found.'
    ,@v_vch_resource_tH    = N'ไม่พบรายการสินค้าคงคลัง'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INV_STATUS_REQUIRED'
    ,@v_vch_resource_en    = 'Inventory status is required.'
    ,@v_vch_resource_tH    = N'กรุณาระบุ Inventory Status'
    ,@v_vch_schema         = 'inv';
GO

-- ── QUANTITY ───────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INVALID_QTY'
    ,@v_vch_resource_en    = 'Quantity must be greater than 0.'
    ,@v_vch_resource_tH    = N'จำนวนต้องมากกว่า 0'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_QTY_EXCEEDS_AVAILABLE'
    ,@v_vch_resource_en    = 'Quantity exceeds available stock.'
    ,@v_vch_resource_tH    = N'จำนวนเกินสต็อกคงเหลือ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_QTY_ALLOCATED'
    ,@v_vch_resource_en    = 'Cannot process because the quantity is allocated.'
    ,@v_vch_resource_tH    = N'ไม่สามารถดำเนินการได้เนื่องจากสินค้าติด Allocated'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_QTY_EXCEEDS_PLAN'
    ,@v_vch_resource_en    = 'Quantity exceeds the planned quantity.'
    ,@v_vch_resource_tH    = N'จำนวนเกินจำนวนที่วางแผนไว้'
    ,@v_vch_schema         = 'inv';
GO

-- ── UOM ────────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_UOM_NOT_FOUND'
    ,@v_vch_resource_en    = 'Unit of measure not found.'
    ,@v_vch_resource_tH    = N'ไม่พบหน่วยนับในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_BASE_UOM_NOT_FOUND'
    ,@v_vch_resource_en    = 'Base unit of measure not found for this item.'
    ,@v_vch_resource_tH    = N'ไม่พบหน่วยนับหลักของสินค้านี้'
    ,@v_vch_schema         = 'inv';
GO

-- ── LOT ────────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_LOT_REQUIRED'
    ,@v_vch_resource_en    = 'Lot number is required for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้จำเป็นต้องระบุ Lot Number'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_LOT_MUST_BE_EMPTY'
    ,@v_vch_resource_en    = 'Lot number must not be specified for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้ไม่ใช้ Lot Number กรุณาอย่าระบุ Lot'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_LOT_MISMATCH'
    ,@v_vch_resource_en    = 'Lot number does not match the plan.'
    ,@v_vch_resource_tH    = N'Lot Number ไม่ตรงกับที่วางแผนไว้'
    ,@v_vch_schema         = 'inv';
GO

-- ── EXPIRY ─────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_EXPIRY_REQUIRED'
    ,@v_vch_resource_en    = 'Expiry date is required for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้จำเป็นต้องระบุวันหมดอายุ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_EXPIRY_MUST_BE_EMPTY'
    ,@v_vch_resource_en    = 'Expiry date must not be specified for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้ไม่ใช้วันหมดอายุ กรุณาอย่าระบุวันหมดอายุ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_EXPIRY_MISMATCH'
    ,@v_vch_resource_en    = 'Expiry date does not match the plan.'
    ,@v_vch_resource_tH    = N'วันหมดอายุไม่ตรงกับที่วางแผนไว้'
    ,@v_vch_schema         = 'inv';
GO

-- ── SERIAL ─────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_REQUIRED'
    ,@v_vch_resource_en    = 'Serial number is required for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้จำเป็นต้องระบุ Serial Number'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_MUST_BE_EMPTY'
    ,@v_vch_resource_en    = 'Serial number must not be specified for this item.'
    ,@v_vch_resource_tH    = N'สินค้านี้ไม่ใช้ Serial Number กรุณาอย่าระบุ Serial'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_DUPLICATE'
    ,@v_vch_resource_en    = 'Serial number [@param1] already exists in the system.'
    ,@v_vch_resource_tH    = N'Serial Number [@param1] มีอยู่ในระบบแล้ว'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_NOT_FOUND'
    ,@v_vch_resource_en    = 'Serial number not found in this inventory.'
    ,@v_vch_resource_tH    = N'ไม่พบ Serial Number ในรายการสินค้าคงคลังนี้'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_REMAINING'
    ,@v_vch_resource_en    = 'Cannot delete inventory because serial numbers are still linked to this record.'
    ,@v_vch_resource_tH    = N'ไม่สามารถลบรายการ Inventory ได้เนื่องจากยังมี Serial Number ที่อ้างอิงอยู่'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_SERIAL_MISMATCH'
    ,@v_vch_resource_en    = 'Serial number does not match the plan.'
    ,@v_vch_resource_tH    = N'Serial Number ไม่ตรงกับที่วางแผนไว้'
    ,@v_vch_schema         = 'inv';
GO

-- ── ADJUSTMENT ─────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INVALID_ADJ_TYPE'
    ,@v_vch_resource_en    = 'Invalid adjustment type.'
    ,@v_vch_resource_tH    = N'ประเภทการปรับสต็อกไม่ถูกต้อง'
    ,@v_vch_schema         = 'inv';
GO

-- ── INBOUND ORDER ──────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_ORDER_TYPE_NOT_FOUND'
    ,@v_vch_resource_en    = 'Order type not found.'
    ,@v_vch_resource_tH    = N'ไม่พบประเภทใบสั่งในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INBOUND_ORDER_NOT_FOUND'
    ,@v_vch_resource_en    = 'Inbound order not found.'
    ,@v_vch_resource_tH    = N'ไม่พบใบสั่งรับสินค้าในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_ORDER_CLOSED'
    ,@v_vch_resource_en    = 'This inbound order is already closed.'
    ,@v_vch_resource_tH    = N'ใบรับสินค้านี้ถูกปิดแล้ว'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_INBOUND_ALREADY_CLOSE'
    ,@v_vch_resource_en    = 'This inbound order/receipt is already closed.'
    ,@v_vch_resource_tH    = N'ใบรับสินค้านี้ถูกปิดแล้ว'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_RECEIPT_STILL_OPEN'
    ,@v_vch_resource_en    = 'Cannot close order because there are still open receipts.'
    ,@v_vch_resource_tH    = N'ไม่สามารถปิดใบสั่งได้เนื่องจากยังมีใบรับสินค้าที่ยังเปิดอยู่'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_RECEIPT_HEADER_NOT_FOUND'
    ,@v_vch_resource_en    = 'Receipt header not found.'
    ,@v_vch_resource_tH    = N'ไม่พบใบรับสินค้าในระบบ'
    ,@v_vch_schema         = 'inv';
GO

-- ── COUNT ──────────────────────────────────────────────────

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_COUNT_NUMBER_REQUIRED'
    ,@v_vch_resource_en    = 'Count number is required.'
    ,@v_vch_resource_tH    = N'กรุณาระบุเลขที่ใบนับสต็อก'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_COUNT_MASTER_NOT_FOUND'
    ,@v_vch_resource_en    = 'Count master not found.'
    ,@v_vch_resource_tH    = N'ไม่พบใบนับสต็อกในระบบ'
    ,@v_vch_schema         = 'inv';
GO

EXEC [sec].[usp_insert_resource]
     @v_vch_app_id         = '28'
    ,@v_vch_platfrom       = 'STORED PROCEDURE'
    ,@v_vch_resource_group = 'STORED_PROCEDURE'
    ,@v_vch_resource_name  = 'ERR_COUNT_ALREADY_CLOSED'
    ,@v_vch_resource_en    = 'This count has already been closed.'
    ,@v_vch_resource_tH    = N'ใบนับสต็อกนี้ถูกปิดแล้ว'
    ,@v_vch_schema         = 'inv';
GO
