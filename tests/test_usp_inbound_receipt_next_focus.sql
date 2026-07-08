USE [MyInventory]
GO

-- ============================================================
-- TEST SCRIPT : usp_inbound_receipt — @out_vch_next_focus
-- ============================================================
-- ครอบคลุมทั้ง 7 Item Control Combinations + No Control
-- ใช้ item ที่มีอยู่จริงในฐานข้อมูล (ไม่ INSERT test item)
--
-- CASE | Controls            | Test Steps
-- -----|---------------------|--------------------------------------
--   1  | Lot + Expired + SN  | SN ยังไม่ครบ group           -> SN
--      |                     | SN ครบ group, overall ไม่ครบ -> LOT
--      |                     | overall ครบ                  -> CLEAR
--   2  | Lot + Expired       | overall ไม่ครบ               -> LOT
--      |                     | overall ครบ                  -> CLEAR
--   3  | Lot + SN            | SN ยังไม่ครบ Lot group       -> SN
--      |                     | SN ครบ Lot group, overall ไม่ครบ -> LOT
--      |                     | overall ครบ                  -> CLEAR
--   4  | Expired + SN        | SN ยังไม่ครบ Expiry group    -> SN
--      |                     | SN ครบ Expiry group, overall ไม่ครบ -> EXPIRED
--      |                     | overall ครบ                  -> CLEAR
--   5  | Lot only            | overall ไม่ครบ               -> LOT
--      |                     | overall ครบ                  -> CLEAR
--   6  | Expired only        | overall ไม่ครบ               -> EXPIRED
--      |                     | overall ครบ                  -> CLEAR
--   7  | SN only             | overall ไม่ครบ               -> SN
--      |                     | overall ครบ                  -> CLEAR
--   8  | No Control          | overall ไม่ครบ               -> QTY
--      |                     | overall ครบ                  -> CLEAR
--   9  | Lot+Expired+SN (Null Plan) | SN ยังไม่ครบ -> SN, ครบ -> CLEAR
--  10  | Lot+SN (Null Plan)  | SN ยังไม่ครบ -> SN, ครบ -> CLEAR
--  11  | Expired+SN (Null Plan) | SN ยังไม่ครบ -> SN, ครบ -> CLEAR
--
-- ** ทุกอย่าง ROLLBACK ท้าย script ไม่กระทบ production data **
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT OFF;

-- ============================================================
-- ตาราง collect ผลลัพธ์
-- ============================================================
DECLARE @results TABLE (
    test_id   INT IDENTITY(1,1),
    case_name NVARCHAR(100),
    step_desc NVARCHAR(200),
    expected  NVARCHAR(20),
    actual    NVARCHAR(20),
    err_code  VARCHAR(50),
    result    AS CASE WHEN expected = actual THEN N'PASS' ELSE N'FAIL' END
);

-- ============================================================
-- Output variables
-- ============================================================
DECLARE
    @o_order   NVARCHAR(50),
    @o_focus   NVARCHAR(20),
    @o_code    VARCHAR(50),
    @o_msg     NVARCHAR(255);

DECLARE
    @LANG      VARCHAR(20)   = 'TH',
    @USER      NVARCHAR(50)  = 'TEST_SCRIPT',
    @DEVICE    NVARCHAR(50)  = 'TEST';

DECLARE
    @loc_id     INT,
    @wh_id      INT,
    @wh         NVARCHAR(50),
    @owner_id   INT,
    @owner      NVARCHAR(50),
    @ord_type   NVARCHAR(50);

DECLARE
    @item_id    INT,
    @uom        NVARCHAR(10),
    @master_id  BIGINT,
    @detail_id  BIGINT,
    @detail2_id BIGINT,
    @skipped    BIT;

BEGIN TRANSACTION;

BEGIN TRY

    -- ============================================================
    -- Prereq: ดึง active location / warehouse / owner / order_type
    -- ============================================================
    SELECT TOP 1 @loc_id   = location_id
    FROM [inv].[t_inv_location] WHERE is_active = 1 ORDER BY location_id;

    SELECT TOP 1 @wh_id    = warehouse_id, @wh    = warehouse
    FROM [inv].[t_inv_warehouse] WHERE is_active = 1 ORDER BY warehouse_id;

    SELECT TOP 1 @owner_id = owner_id,     @owner = owner_code
    FROM [inv].[t_inv_owner] WHERE is_active = 1 ORDER BY owner_id;

    SELECT TOP 1 @ord_type = value_member
    FROM [sec].[t_com_combobox_item]
    WHERE group_name = 'inbound_order_type' AND is_active = 1 ORDER BY display_sequence;

    IF @loc_id   IS NULL RAISERROR('PREREQ FAILED: No active location found',         16, 1);
    IF @wh_id    IS NULL RAISERROR('PREREQ FAILED: No active warehouse found',         16, 1);
    IF @owner_id IS NULL RAISERROR('PREREQ FAILED: No active owner found',             16, 1);
    IF @ord_type IS NULL RAISERROR('PREREQ FAILED: No inbound_order_type in combobox', 16, 1);


    -- ===========================================================
    -- Helper: สร้าง inbound master + 2 detail lines สำหรับ test
    -- (ใช้ซ้ำในทุก case ที่ต้องการ 2 detail groups)
    -- ===========================================================


    -- ============================================================
    -- CASE 1: Lot + Expired + SN
    --   หา item ที่ lot='Full', expiry='Full', sn='Full'
    --   Detail A: LOT-A / 2026-12-31  qty_order=2
    --   Detail B: LOT-B / 2027-06-30  qty_order=1
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         = 'Full'
      AND i.expiry_date_control = 'Full'
      AND i.sn_control          = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 1: Lot+Expired+SN', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C1-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        -- Detail A: LOT-A qty=2
        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C1-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', 'LOT-A', '2026-12-31', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Detail B: LOT-B qty=1
        SET @detail2_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail2_id, @master_id, CONCAT('TEST-C1-', @master_id), '00002', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 1, 0,
               'Available', 'LOT-B', '2027-06-30', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Step 1a: SN-A001 (LOT-A group 1/2) -> SN
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-A',
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-A001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 1: Lot+Expired+SN', '1a: SN-A001 -> LOT-A group 1/2 (ยังไม่ครบ)', 'SN', @o_focus, @o_code);

        -- Step 1b: SN-A002 (LOT-A group 2/2, overall 2/3) -> LOT
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-A',
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-A002',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 1: Lot+Expired+SN', '1b: SN-A002 -> LOT-A group done, overall 2/3', 'LOT', @o_focus, @o_code);

        -- Step 1c: SN-B001 (overall 3/3) -> CLEAR
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail2_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-B',
            @in_dt_expiry_date            = '2027-06-30',
            @in_vch_serial_number         = 'SN-B001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 1: Lot+Expired+SN', '1c: SN-B001 -> overall 3/3', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 2: Lot + Expired  (SN=NONE)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         = 'Full'
      AND i.expiry_date_control = 'Full'
      AND i.sn_control         != 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 2: Lot+Expired', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp=Full, SN!=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C2-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C2-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 5, 0,
               'Available', 'LOT-X', '2026-12-31', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @detail2_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail2_id, @master_id, CONCAT('TEST-C2-', @master_id), '00002', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 3, 0,
               'Available', 'LOT-Y', '2027-01-01', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Step 2a: receive LOT-X (5/8) -> LOT
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 5,
            @in_vch_lot_number            = 'LOT-X',
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = NULL,
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 2: Lot+Expired', '2a: receive LOT-X 5 pcs (overall 5/8)', 'LOT', @o_focus, @o_code);

        -- Step 2b: receive LOT-Y (8/8) -> CLEAR
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail2_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 3,
            @in_vch_lot_number            = 'LOT-Y',
            @in_dt_expiry_date            = '2027-01-01',
            @in_vch_serial_number         = NULL,
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 2: Lot+Expired', '2b: receive LOT-Y 3 pcs (overall 8/8)', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 3: Lot + SN  (Expired=NONE)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control          = 'Full'
      AND i.expiry_date_control != 'Full'
      AND i.sn_control           = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 3: Lot+SN', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp!=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C3-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C3-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', 'LOT-P', NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @detail2_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail2_id, @master_id, CONCAT('TEST-C3-', @master_id), '00002', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 1, 0,
               'Available', 'LOT-Q', NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-P',
            @in_dt_expiry_date            = NULL,
            @in_vch_serial_number         = 'SN-P001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 3: Lot+SN', '3a: SN-P001 -> LOT-P group 1/2', 'SN', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-P',
            @in_dt_expiry_date            = NULL,
            @in_vch_serial_number         = 'SN-P002',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 3: Lot+SN', '3b: SN-P002 -> LOT-P group done, overall 2/3', 'LOT', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail2_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-Q',
            @in_dt_expiry_date            = NULL,
            @in_vch_serial_number         = 'SN-Q001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 3: Lot+SN', '3c: SN-Q001 -> overall 3/3', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 4: Expired + SN  (Lot=NONE)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         != 'Full'
      AND i.expiry_date_control  = 'Full'
      AND i.sn_control           = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 4: Expired+SN', '-- SKIPPED: ไม่พบ item ที่ Lot!=Full, Exp=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C4-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C4-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', NULL, '2026-12-31', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @detail2_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail2_id, @master_id, CONCAT('TEST-C4-', @master_id), '00002', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 1, 0,
               'Available', NULL, '2027-06-30', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 1,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = '2026-12-31',  @in_vch_serial_number     = 'SN-E001',
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 4: Expired+SN', '4a: SN-E001 -> Exp 2026-12-31 group 1/2', 'SN', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 1,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = '2026-12-31',  @in_vch_serial_number     = 'SN-E002',
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 4: Expired+SN', '4b: SN-E002 -> Exp-A done, overall 2/3', 'EXPIRED', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail2_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 1,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = '2027-06-30',  @in_vch_serial_number     = 'SN-F001',
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 4: Expired+SN', '4c: SN-F001 -> overall 3/3', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 5: Lot เท่านั้น  (Expired!=Full, SN!=Full)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control          = 'Full'
      AND i.expiry_date_control != 'Full'
      AND i.sn_control          != 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 5: Lot only', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp!=Full, SN!=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C5-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C5-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 10, 0,
               'Available', 'LOT-AA', NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 6,             @in_vch_lot_number        = 'LOT-AA',
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 5: Lot only', '5a: receive 6/10 -> LOT', 'LOT', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 4,             @in_vch_lot_number        = 'LOT-AA',
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 5: Lot only', '5b: receive 4 remaining (10/10) -> CLEAR', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 6: Expired เท่านั้น  (Lot!=Full, SN!=Full)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         != 'Full'
      AND i.expiry_date_control  = 'Full'
      AND i.sn_control          != 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 6: Expired only', '-- SKIPPED: ไม่พบ item ที่ Lot!=Full, Exp=Full, SN!=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C6-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C6-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 8, 0,
               'Available', NULL, '2026-06-30', NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 3,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = '2026-06-30',  @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 6: Expired only', '6a: receive 3/8 -> EXPIRED', 'EXPIRED', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 5,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = '2026-06-30',  @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 6: Expired only', '6b: receive 5 remaining (8/8) -> CLEAR', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 7: SN เท่านั้น  (Lot!=Full, Expired!=Full)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         != 'Full'
      AND i.expiry_date_control != 'Full'
      AND i.sn_control           = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 7: SN only', '-- SKIPPED: ไม่พบ item ที่ Lot!=Full, Exp!=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C7-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C7-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', NULL, NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 1,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = 'SN-001',
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 7: SN only', '7a: SN-001 -> overall 1/2 -> SN', 'SN', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 1,             @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = 'SN-002',
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 7: SN only', '7b: SN-002 -> overall 2/2 -> CLEAR', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 8: No Control  (ทุก control != Full)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         != 'Full'
      AND i.expiry_date_control != 'Full'
      AND i.sn_control          != 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 8: No Control', '-- SKIPPED: ไม่พบ item ที่ทุก control ไม่ใช่ Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C8-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C8-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 20, 0,
               'Available', NULL, NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 10,            @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 8: No Control', '8a: receive 10/20 -> QTY', 'QTY', @o_focus, @o_code);

        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id = @master_id,    @in_int_inbound_detail_id = @detail_id,
            @in_int_item_master_id    = @item_id,      @in_vch_uom               = @uom,
            @in_dec_qty               = 10,            @in_vch_lot_number        = NULL,
            @in_dt_expiry_date        = NULL,           @in_vch_serial_number     = NULL,
            @in_int_receipt_location_id = @loc_id,     @in_vch_lang              = @LANG,
            @in_vch_user_id           = @USER,         @in_vch_device            = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 8: No Control', '8b: receive 10 remaining (20/20) -> CLEAR', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 9: Lot + Expired + SN (Plan has NULL Lot & Expiry)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         = 'Full'
      AND i.expiry_date_control = 'Full'
      AND i.sn_control          = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 9: Lot+Expired+SN (Null Plan)', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C9-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        -- Detail A: NULL lot/expiry qty=2
        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C9-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', NULL, NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Step 9a: SN-T001 (LOT-TEST group 1/2) -> SN
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-TEST',
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-T001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 9: Lot+Expired+SN (Null Plan)', '9a: SN-T001 -> LOT-TEST (1/2, expected SN)', 'SN', @o_focus, @o_code);

        -- Step 9b: SN-T002 (LOT-TEST group 2/2) -> CLEAR
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-TEST',
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-T002',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 9: Lot+Expired+SN (Null Plan)', '9b: SN-T002 -> LOT-TEST (2/2, expected CLEAR)', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 10: Lot + SN (Plan has NULL Lot)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control          = 'Full'
      AND i.expiry_date_control != 'Full'
      AND i.sn_control           = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 10: Lot+SN (Null Plan)', '-- SKIPPED: ไม่พบ item ที่ Lot=Full, Exp!=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C10-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        -- Detail A: NULL lot qty=2
        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C10-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', NULL, NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Step 10a: SN-U001 (LOT-TEST-10 1/2) -> SN
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-TEST-10',
            @in_dt_expiry_date            = NULL,
            @in_vch_serial_number         = 'SN-U001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 10: Lot+SN (Null Plan)', '10a: SN-U001 -> LOT-TEST-10 (1/2, expected SN)', 'SN', @o_focus, @o_code);

        -- Step 10b: SN-U002 (LOT-TEST-10 2/2) -> CLEAR
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = 'LOT-TEST-10',
            @in_dt_expiry_date            = NULL,
            @in_vch_serial_number         = 'SN-U002',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 10: Lot+SN (Null Plan)', '10b: SN-U002 -> LOT-TEST-10 (2/2, expected CLEAR)', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- CASE 11: Expired + SN (Plan has NULL Expiry)
    -- ============================================================
    SET @skipped = 0;
    SET @item_id = NULL; SET @uom = NULL;

    SELECT TOP 1
        @item_id = i.item_master_id,
        @uom     = u.uom
    FROM [inv].[t_inv_item] i
    INNER JOIN [inv].[t_inv_item_uom] u
        ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
    WHERE i.lot_control         != 'Full'
      AND i.expiry_date_control  = 'Full'
      AND i.sn_control           = 'Full'
    ORDER BY i.item_master_id;

    IF @item_id IS NULL
    BEGIN
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 11: Expired+SN (Null Plan)', '-- SKIPPED: ไม่พบ item ที่ Lot!=Full, Exp=Full, SN=Full --', 'N/A', 'N/A', 'SKIP');
        SET @skipped = 1;
    END

    IF @skipped = 0
    BEGIN
        SET @master_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_master]
            (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code,
             order_type, order_status, order_date, create_by, create_date)
        VALUES (@master_id, CONCAT('TEST-C11-', @master_id), @wh_id, @wh, @owner_id, @owner,
                @ord_type, 'Receiving', GETDATE(), @USER, GETDATE());

        -- Detail A: NULL expiry qty=2
        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail]
            (inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
             item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
             inv_status, lot_number, expiry_date, serial_number, create_by, create_date)
        SELECT @detail_id, @master_id, CONCAT('TEST-C11-', @master_id), '00001', i.item_master_id,
               i.item_number, i.description, u.item_uom_id, u.uom, 2, 0,
               'Available', NULL, NULL, NULL, @USER, GETDATE()
        FROM [inv].[t_inv_item] i
        JOIN [inv].[t_inv_item_uom] u ON i.item_master_id = u.item_master_id AND u.primary_uom = 1
        WHERE i.item_master_id = @item_id;

        -- Step 11a: SN-V001 (Exp 2026-12-31 1/2) -> SN
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = NULL,
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-V001',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 11: Expired+SN (Null Plan)', '11a: SN-V001 -> Exp 2026-12-31 (1/2, expected SN)', 'SN', @o_focus, @o_code);

        -- Step 11b: SN-V002 (Exp 2026-12-31 2/2) -> CLEAR
        SET @o_focus = NULL; SET @o_code = NULL;
        EXEC [inv].[usp_inbound_receipt]
            @in_int_inbound_master_id     = @master_id,
            @in_int_inbound_detail_id     = @detail_id,
            @in_int_item_master_id        = @item_id,
            @in_vch_uom                   = @uom,
            @in_dec_qty                   = 1,
            @in_vch_lot_number            = NULL,
            @in_dt_expiry_date            = '2026-12-31',
            @in_vch_serial_number         = 'SN-V002',
            @in_int_receipt_location_id   = @loc_id,
            @in_vch_lang                  = @LANG,
            @in_vch_user_id               = @USER,
            @in_vch_device                = @DEVICE,
            @out_vch_inbound_order_number = @o_order OUTPUT,
            @out_vch_next_focus           = @o_focus  OUTPUT,
            @out_vch_error_code           = @o_code   OUTPUT,
            @out_vch_error_message        = @o_msg    OUTPUT;
        INSERT INTO @results (case_name, step_desc, expected, actual, err_code)
        VALUES ('Case 11: Expired+SN (Null Plan)', '11b: SN-V002 -> Exp 2026-12-31 (2/2, expected CLEAR)', 'CLEAR', @o_focus, @o_code);
    END


    -- ============================================================
    -- แสดงผลลัพธ์ทั้งหมด
    -- ============================================================
    SELECT
        test_id,
        case_name,
        step_desc,
        expected,
        actual,
        err_code,
        result
    FROM @results
    ORDER BY test_id;

    -- Summary
    SELECT
        COUNT(*)                                                         AS total_tests,
        SUM(CASE WHEN result = 'PASS'    THEN 1 ELSE 0 END)             AS passed,
        SUM(CASE WHEN result = 'FAIL'    THEN 1 ELSE 0 END)             AS failed,
        SUM(CASE WHEN err_code = 'SKIP'  THEN 1 ELSE 0 END)             AS skipped
    FROM @results;

END TRY
BEGIN CATCH
    PRINT N'ERROR: ' + ERROR_MESSAGE();
    PRINT N'Line : ' + CAST(ERROR_LINE() AS NVARCHAR(10));

    IF (SELECT COUNT(*) FROM @results) > 0
        SELECT test_id, case_name, step_desc, expected, actual, err_code, result
        FROM @results ORDER BY test_id;
END CATCH;

-- ============================================================
-- ROLLBACK เสมอ ไม่กระทบ production data
-- ============================================================
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
PRINT N'Transaction rolled back - no permanent changes made.';
GO
