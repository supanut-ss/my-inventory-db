USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inventory_adjustment_new_stock]
-- Purpose : เพิ่ม inventory ใหม่ (ADJUST_IN) สำหรับ item ที่ยังไม่มีใน inventory
--           รองรับ Lot / Expiry / Serial Control
-- ============================================================
-- PARAMETER CONVENTIONS (เรียงลำดับเหมือนกันทุก Stored Procedure)
--   1. item_number / location      (ตัวระบุ item และ location)
--   2. lot_number / expiry_date    (lot & expiry control)
--   3. serial_number               (serial control)
--   4. operation-specific params   (เฉพาะ SP นี้ เช่น qty, inv_status, receive_date)
--   5. reason / description        (หมายเหตุ)
--   6. lang / device / user_id     (context สำหรับ logging และ i18n)
--   7. OUTPUT params               (error_code, error_message)
-- ============================================================
CREATE OR ALTER PROCEDURE [inv].[usp_inventory_adjustment_new_stock]
    -- ── 1. Item & Location ───────────────────────────────────
    @in_vch_item_number             NVARCHAR(50),              -- Item number (required)
    @in_vch_location                NVARCHAR(50),              -- Location code (required)

    -- ── 2. Lot & Expiry Control ───────────────────────────────
    @in_vch_lot_number              NVARCHAR(50)   = NULL,     -- Lot number (จำเป็นเมื่อ lot_control = 'FULL')
    @in_dat_expiry_date             DATE           = NULL,     -- Expiry date (จำเป็นเมื่อ expiry_date_control = 'FULL')

    -- ── 3. Serial Control ─────────────────────────────────────
    @in_vch_serial_number           NVARCHAR(50)   = NULL,     -- Serial number (จำเป็นเมื่อ sn_control = 'FULL')

    -- ── 4. Operation-specific Parameters ─────────────────────
    @in_dec_qty                     DECIMAL(18, 4),            -- จำนวนที่ต้องการเพิ่ม (ต้องมากกว่า 0)
    @in_vch_inv_status              NVARCHAR(50),              -- สถานะ inventory (เช่น 'Available', 'Hold', 'Damaged')
    @in_dat_receive_date            DATE           = NULL,     -- วันที่รับสินค้า (NULL = ใช้ GETDATE())

    -- ── 5. Remark / Description ───────────────────────────────
    @in_vch_remark                 NVARCHAR(200)  = NULL,     -- หมายเหตุการปรับ (บันทึกใน tran_log)

    -- ── 6. Context: Lang / Device / User ─────────────────────
    @in_vch_lang                    VARCHAR(20),               -- รหัสภาษาสำหรับ error message (เช่น 'TH', 'EN')
    @in_vch_device                  NVARCHAR(50)   = NULL,     -- Device ที่ทำรายการ (สำหรับ log)
    @in_vch_user_id                 NVARCHAR(50),              -- User ที่ทำรายการ

    -- ── 7. Output Parameters ──────────────────────────────────
    @out_vch_error_code             VARCHAR(50)    OUTPUT,     -- '0' = สำเร็จ, 'ERR_xxx' = ผิดพลาด
    @out_vch_error_message          NVARCHAR(255)  OUTPUT      -- ข้อความแสดงผล (ดึงจาก resource table)
AS
BEGIN
    SET NOCOUNT ON;

    -- ============================================================
    -- Internal Variables
    -- ============================================================
    DECLARE
        @v_vch_error_code               VARCHAR(50),
        @v_vch_error_message            NVARCHAR(255),
        -- Warehouse & Owner
        @v_int_warehouse_id             INT,
        @v_vch_warehouse                NVARCHAR(50),
        @v_int_owner_id                 INT,
        @v_vch_owner_code               NVARCHAR(50),
        -- Location
        @v_int_location_id              INT,
        @v_vch_location                 NVARCHAR(50),
        -- Item
        @v_int_item_master_id           INT,
        @v_vch_item_number              NVARCHAR(50),
        @v_vch_item_description         NVARCHAR(200),
        -- UOM
        @v_int_item_uom_id              INT,
        @v_vch_uom                      NVARCHAR(10),
        -- Item Control Flags
        @v_vch_lot_control              VARCHAR(10),
        @v_vch_expiry_control           VARCHAR(10),
        @v_vch_sn_control               VARCHAR(10),
        -- Inventory
        @v_int_inventory_id             BIGINT,
        @v_int_serial_exists            INT,
        @v_dat_receive_date             DATE,
        -- Process Tracking
        @v_dt_process_start             DATETIME      = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- กำหนด receive_date: ถ้าไม่ได้ส่งมาให้ใช้ GETDATE()
        SET @v_dat_receive_date = ISNULL(@in_dat_receive_date, CAST(GETDATE() AS DATE));

        -- ============================================================
        -- STEP 0: Resolve Warehouse, Owner, Location, Item
        -- ============================================================

        -- หา default warehouse (active, เก่าสุด)
        SELECT TOP 1
            @v_int_warehouse_id = warehouse_id,
            @v_vch_warehouse    = warehouse
        FROM [inv].[t_inv_warehouse]
        WHERE is_active = 1
        ORDER BY warehouse_id ASC;

        -- หา default owner (active, เก่าสุด)
        SELECT TOP 1
            @v_int_owner_id   = owner_id,
            @v_vch_owner_code = owner_code
        FROM [inv].[t_inv_owner]
        WHERE is_active = 1
        ORDER BY owner_id ASC;

        -- หา location_id จาก location code
        SELECT
            @v_int_location_id = location_id,
            @v_vch_location    = location
        FROM [inv].[t_inv_location]
        WHERE location    = @in_vch_location
          AND is_active   = 1;

        -- หา item_master_id และข้อมูล item จาก item_number
        SELECT
            @v_int_item_master_id   = itm.item_master_id,
            @v_vch_item_number      = itm.item_number,
            @v_vch_item_description = itm.description,
            @v_vch_lot_control      = itm.lot_control,
            @v_vch_expiry_control   = itm.expiry_date_control,
            @v_vch_sn_control       = itm.sn_control
        FROM [inv].[t_inv_item] itm
        WHERE itm.item_number = @in_vch_item_number
          AND itm.is_active   = 1;

        -- ดึง UOM หลักของ item
        SELECT TOP 1
            @v_int_item_uom_id = iuom.item_uom_id,
            @v_vch_uom         = iuom.uom
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_master_id = @v_int_item_master_id
          AND iuom.primary_uom    = 1;

        -- ============================================================
        -- STEP 1: Validation
        -- ============================================================
        SELECT @v_vch_error_code = CASE
            WHEN ISNULL(@in_vch_item_number, '') = ''
                THEN 'ERR_ITEM_REQUIRED'                        -- ไม่ได้ส่ง item_number มา
            WHEN @v_int_item_master_id IS NULL
                THEN 'ERR_ITEM_NOT_FOUND'                       -- ไม่พบ item ในระบบ
            WHEN ISNULL(@in_vch_location, '') = ''
                THEN 'ERR_LOCATION_REQUIRED'                    -- ไม่ได้ส่ง location มา
            WHEN @v_int_location_id IS NULL
                THEN 'ERR_LOCATION_NOT_FOUND'                   -- ไม่พบ location ในระบบ
            WHEN @in_dec_qty <= 0
                THEN 'ERR_INVALID_QTY'                          -- จำนวนต้องมากกว่า 0
            WHEN ISNULL(@in_vch_inv_status, '') = ''
                THEN 'ERR_INV_STATUS_REQUIRED'                  -- ไม่ได้ส่ง inv_status มา
            WHEN @v_vch_lot_control = 'FULL' AND ISNULL(@in_vch_lot_number, '') = ''
                THEN 'ERR_LOT_REQUIRED'                         -- item ต้องการ lot แต่ไม่ได้ส่งมา
            WHEN @v_vch_lot_control = 'NONE' AND ISNULL(@in_vch_lot_number, '') <> ''
                THEN 'ERR_LOT_MUST_BE_EMPTY'                    -- item ไม่ใช้ lot แต่ส่ง lot มา
            WHEN @v_vch_expiry_control = 'FULL' AND @in_dat_expiry_date IS NULL
                THEN 'ERR_EXPIRY_REQUIRED'                      -- item ต้องการ expiry แต่ไม่ได้ส่งมา
            WHEN @v_vch_expiry_control = 'NONE' AND @in_dat_expiry_date IS NOT NULL
                THEN 'ERR_EXPIRY_MUST_BE_EMPTY'                 -- item ไม่ใช้ expiry แต่ส่ง expiry มา
            WHEN @v_vch_sn_control = 'FULL' AND ISNULL(@in_vch_serial_number, '') = ''
                THEN 'ERR_SERIAL_REQUIRED'                      -- item ต้องการ serial แต่ไม่ได้ส่งมา
            WHEN @v_vch_sn_control = 'NONE' AND ISNULL(@in_vch_serial_number, '') <> ''
                THEN 'ERR_SERIAL_MUST_BE_EMPTY'                 -- item ไม่ใช้ serial แต่ส่ง serial มา
            ELSE 'SUCCESS'
        END;

        -- ตรวจ serial ซ้ำสำหรับ ADJUST_IN (serial ต้องไม่มีในระบบ)
        IF @v_vch_sn_control = 'FULL'
            AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            INNER JOIN [inv].[t_inv_inventory] inv
                ON invs.inventory_id = inv.inventory_id
            WHERE inv.item_master_id = @v_int_item_master_id
              AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists > 0
                SET @v_vch_error_code = 'ERR_SERIAL_DUPLICATE';  -- Serial นี้มีในระบบแล้ว
        END

        -- หยุดทำงานและ return error ถ้า validation ไม่ผ่าน
        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE', @out_vch_error_code, @in_vch_lang, '@param1', '@param2', '@param3', '@param4', '@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- ============================================================
        -- STEP 2: Insert Inventory Record ใหม่
        -- ============================================================
        INSERT INTO [inv].[t_inv_inventory] (
            warehouse_id,
            warehouse,
            owner_id,
            owner_code,
            location_id,
            location,
            item_master_id,
            item_number,
            item_description,
            quantity,
            inv_status,
            lot_number,
            expiry_date,
            receive_date,
            create_by,
            create_date,
            update_by,
            update_date
        )
        VALUES (
            @v_int_warehouse_id,
            @v_vch_warehouse,
            @v_int_owner_id,
            @v_vch_owner_code,
            @v_int_location_id,
            @v_vch_location,
            @v_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @in_dec_qty,
            @in_vch_inv_status,
            @in_vch_lot_number,
            @in_dat_expiry_date,
            @v_dat_receive_date,
            @in_vch_user_id,
            GETDATE(),
            @in_vch_user_id,
            GETDATE()
        );

        -- ดึง inventory_id ที่เพิ่งสร้าง
        SET @v_int_inventory_id = SCOPE_IDENTITY();

        -- ============================================================
        -- STEP 3: จัดการ Serial (ถ้า sn_control = 'FULL')
        -- ============================================================
        IF @v_vch_sn_control = 'FULL'
        BEGIN
            INSERT INTO [inv].[t_inv_inventory_serial] (
                inventory_id,
                serial_number,
                create_by,
                create_date
            )
            VALUES (
                @v_int_inventory_id,
                @in_vch_serial_number,
                @in_vch_user_id,
                GETDATE()
            );
        END

        -- ============================================================
        -- STEP 4: บันทึก Transaction Log
        -- ============================================================
        INSERT INTO [inv].[t_inv_tran_log] (
            tran_type,
            -- ประเภทธุรกรรมหลัก
            sub_tran_type,
            -- ประเภทธุรกรรมย่อย
            description,
            -- หมายเหตุการปรับ
            warehouse_id,
            warehouse,
            owner_id,
            owner_code,
            location_id,
            location,
            after_location_id,
            -- ไม่เปลี่ยน location ใน adjustment
            after_location,
            item_master_id,
            item_number,
            item_description,
            quantity,
            item_uom_id,
            uom,
            inv_status,
            after_inv_status,
            -- ไม่เปลี่ยน status ใน adjustment
            receive_date,
            lot_number,
            after_lot_number,
            -- ไม่เปลี่ยน lot ใน adjustment
            expiry_date,
            after_expiry_date,
            -- ไม่เปลี่ยน expiry ใน adjustment
            serial_number,
            device,
            create_by,
            create_date,
            remark
        )
        VALUES (
            'ADJUSTMENT',
            'ADJUST_IN',
            'Inventory adjustment - Add new stock',
            @v_int_warehouse_id,
            @v_vch_warehouse,
            @v_int_owner_id,
            @v_vch_owner_code,
            @v_int_location_id,
            @v_vch_location,
            @v_int_location_id,
            -- location ไม่เปลี่ยน
            @v_vch_location,
            @v_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @in_dec_qty,
            @v_int_item_uom_id,
            @v_vch_uom,
            @in_vch_inv_status,
            @in_vch_inv_status,
            -- status ไม่เปลี่ยน
            @v_dat_receive_date,
            @in_vch_lot_number,
            @in_vch_lot_number,
            -- lot ไม่เปลี่ยน
            @in_dat_expiry_date,
            @in_dat_expiry_date,
            -- expiry ไม่เปลี่ยน
            @in_vch_serial_number,
            @in_vch_device,
            @in_vch_user_id,
            GETDATE(),
            @in_vch_remark
        );

        COMMIT TRANSACTION;
        SET @out_vch_error_code    = '0';
        SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE', 'SAVE_SUCCESS', @in_vch_lang, '@param1', '@param2', '@param3', '@param4', '@param5');

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_vch_error_code    = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();

        -- บันทึก error log
        EXEC [inv].usp_process_log
             @in_vch_log_type        = 'STORE_PROCEDURE'
            ,@in_vch_device          = @in_vch_device
            ,@in_vch_process         = 'usp_inventory_adjustment_new_stock'
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = @out_vch_error_code
            ,@out_vch_error_message  = @out_vch_error_message
            ,@in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
