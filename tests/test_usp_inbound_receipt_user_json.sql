USE [MyInventory]
GO

-- ============================================================
-- TEST SCRIPT : User Scenario for usp_inbound_receipt
-- ============================================================
-- Input JSON:
-- {
--   inbound_master_id: 5,
--   item_master_id: 233,
--   uom: box,
--   language: en,
--   quantity_receive: 1.0,
--   lot_number: lot03,
--   expired_date: 2026-03-03T00:00:00.000,
--   serial_number: sneria1,
--   receipt_location_id: 7,
--   user_id: aotm,
--   device: sdk_gphone64_x86_64
-- }
--
-- Expected Output next_focus: 'SN' (because plan qty is 100, received is 1.0)
-- ============================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @loc_id INT = 7;
    DECLARE @wh_id INT;
    DECLARE @wh NVARCHAR(50);
    DECLARE @owner_id INT;
    DECLARE @owner NVARCHAR(50);
    DECLARE @ord_type NVARCHAR(50);

    -- Prereqs checks & setup
    SELECT TOP 1 @wh_id = warehouse_id, @wh = warehouse FROM [inv].[t_inv_warehouse] WHERE is_active = 1;
    IF @wh_id IS NULL
    BEGIN
        INSERT INTO [inv].[t_inv_warehouse] (warehouse, is_active, create_by, create_date)
        VALUES ('WH-TEST', 1, 'TEST', GETDATE());
        SELECT TOP 1 @wh_id = warehouse_id, @wh = warehouse FROM [inv].[t_inv_warehouse] WHERE is_active = 1;
    END

    SELECT TOP 1 @owner_id = owner_id, @owner = owner_code FROM [inv].[t_inv_owner] WHERE is_active = 1;
    IF @owner_id IS NULL
    BEGIN
        INSERT INTO [inv].[t_inv_owner] (owner_code, owner_name, is_active, create_by, create_date)
        VALUES ('OWNER-TEST', 'Owner Test', 1, 'TEST', GETDATE());
        SELECT TOP 1 @owner_id = owner_id, @owner = owner_code FROM [inv].[t_inv_owner] WHERE is_active = 1;
    END

    SELECT TOP 1 @ord_type = value_member FROM [sec].[t_com_combobox_item] WHERE group_name = 'inbound_order_type' AND is_active = 1;
    IF @ord_type IS NULL
    BEGIN
        SET @ord_type = 'Standard';
    END

    -- Check and Insert Location 7
    IF NOT EXISTS (SELECT 1 FROM [inv].[t_inv_location] WHERE location_id = @loc_id)
    BEGIN
        IF OBJECTPROPERTY(OBJECT_ID('[inv].[t_inv_location]'), 'TableHasIdentity') = 1
            SET IDENTITY_INSERT [inv].[t_inv_location] ON;

        INSERT INTO [inv].[t_inv_location] (location_id, location, warehouse_id, is_active, create_by, create_date)
        VALUES (@loc_id, 'LOC-07', @wh_id, 1, 'TEST', GETDATE());

        IF OBJECTPROPERTY(OBJECT_ID('[inv].[t_inv_location]'), 'TableHasIdentity') = 1
            SET IDENTITY_INSERT [inv].[t_inv_location] OFF;
    END

    -- Check and Insert Item 233 (Full Control)
    IF NOT EXISTS (SELECT 1 FROM [inv].[t_inv_item] WHERE item_master_id = 233)
    BEGIN
        IF OBJECTPROPERTY(OBJECT_ID('[inv].[t_inv_item]'), 'TableHasIdentity') = 1
            SET IDENTITY_INSERT [inv].[t_inv_item] ON;

        INSERT INTO [inv].[t_inv_item] (item_master_id, item_number, description, lot_control, expiry_date_control, sn_control, is_active, create_by, create_date)
        VALUES (233, 'ITEM-233', 'Item Full Control 233', 'FULL', 'FULL', 'FULL', 1, 'TEST', GETDATE());

        IF OBJECTPROPERTY(OBJECT_ID('[inv].[t_inv_item]'), 'TableHasIdentity') = 1
            SET IDENTITY_INSERT [inv].[t_inv_item] OFF;
    END

    -- Check and Insert Item UOM 'box'
    IF NOT EXISTS (SELECT 1 FROM [inv].[t_inv_item_uom] WHERE item_master_id = 233 AND uom = 'box')
    BEGIN
        INSERT INTO [inv].[t_inv_item_uom] (item_master_id, uom, conversion_factor, primary_uom, create_by, create_date)
        VALUES (233, 'box', 1.00000, 1, 'TEST', GETDATE());
    END

    -- Check and Insert Inbound Master 5
    IF NOT EXISTS (SELECT 1 FROM [inv].[t_inv_inbound_master] WHERE inbound_master_id = 5)
    BEGIN
        INSERT INTO [inv].[t_inv_inbound_master] (inbound_master_id, inbound_order_number, warehouse_id, warehouse, owner_id, owner_code, order_type, order_status, order_date, create_by, create_date)
        VALUES (5, 'IB202607080002', @wh_id, @wh, @owner_id, @owner, @ord_type, 'Receiving', GETDATE(), 'TEST', GETDATE());
    END

    -- Check and Insert Inbound Detail (quantity_order = 100, lot_number = NULL, expiry_date = NULL)
    DECLARE @detail_id BIGINT;
    SELECT TOP 1 @detail_id = inbound_detail_id FROM [inv].[t_inv_inbound_detail] WHERE inbound_master_id = 5 AND item_master_id = 233;

    IF @detail_id IS NULL
    BEGIN
        SET @detail_id = NEXT VALUE FOR [inv].[SEQInboundID];
        INSERT INTO [inv].[t_inv_inbound_detail] (
            inbound_detail_id, inbound_master_id, inbound_order_number, line_number, item_master_id,
            item_number, item_description, item_uom_id, uom, quantity_order, quantity_received,
            inv_status, lot_number, expiry_date, serial_number, create_by, create_date
        )
        SELECT 
            @detail_id, 5, 'IB202607080002', '00001', 233,
            'ITEM-233', 'Item Full Control 233', item_uom_id, uom, 100.00000, 0.00000,
            'Available', NULL, NULL, NULL, 'TEST', GETDATE()
        FROM [inv].[t_inv_item_uom]
        WHERE item_master_id = 233 AND uom = 'box';
    END
    ELSE
    BEGIN
        -- Reset if already exists to ensure test starts clean
        UPDATE [inv].[t_inv_inbound_detail]
        SET quantity_order = 100.00000,
            quantity_received = 0.00000,
            lot_number = NULL,
            expiry_date = NULL,
            serial_number = NULL
        WHERE inbound_detail_id = @detail_id;
    END

    -- Variables to capture output
    DECLARE
        @o_order NVARCHAR(50),
        @o_focus NVARCHAR(20),
        @o_code VARCHAR(50),
        @o_msg NVARCHAR(255);

    -- Call Stored Procedure with User Input Parameters
    EXEC [inv].[usp_inbound_receipt]
        @in_int_inbound_master_id     = 5,
        @in_int_inbound_detail_id     = @detail_id,
        @in_int_item_master_id        = 233,
        @in_vch_uom                   = 'box',
        @in_dec_qty                   = 1.0,
        @in_vch_lot_number            = 'lot03',
        @in_dt_expiry_date            = '2026-03-03',
        @in_vch_serial_number         = 'sneria1',
        @in_int_receipt_location_id   = 7,
        @in_vch_lang                  = 'en',
        @in_vch_user_id               = 'aotm',
        @in_vch_device                = 'sdk_gphone64_x86_64',
        @out_vch_inbound_order_number = @o_order OUTPUT,
        @out_vch_next_focus           = @o_focus OUTPUT,
        @out_vch_error_code           = @o_code OUTPUT,
        @out_vch_error_message        = @o_msg OUTPUT;

    -- Output results
    SELECT 
        'IB202607080002' AS expected_order_number,
        @o_order AS actual_order_number,
        'SN' AS expected_next_focus,
        @o_focus AS actual_next_focus,
        '0' AS expected_error_code,
        @o_code AS actual_error_code,
        @o_msg AS actual_error_message,
        CASE WHEN @o_focus = 'SN' AND @o_code = '0' THEN 'PASS' ELSE 'FAIL' END AS test_result;

END TRY
BEGIN CATCH
    SELECT 
        ERROR_MESSAGE() AS error_message,
        ERROR_LINE() AS error_line,
        'FAIL_EXCEPTION' AS test_result;
END CATCH;

-- ROLLBACK to keep the DB clean
ROLLBACK TRANSACTION;
PRINT 'Transaction rolled back successfully.';
GO
