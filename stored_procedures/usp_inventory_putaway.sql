USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inventory_putaway]
-- Purpose : ย้ายสินค้าจาก Source Location ไปยัง Target Location
--           รองรับ Partial Put Away และ Serial Control
-- ============================================================
-- PARAMETER CONVENTIONS (เรียงลำดับเหมือนกันทุก Stored Procedure)
--   1. inventory_id / lookup keys  (ตัวระบุ record หลัก)
--   2. item_number / location      (lookup fallback)
--   3. lot_number / expiry_date    (lot & expiry control)
--   4. serial_number               (serial control)
--   5. operation-specific params   (เฉพาะ SP นี้ เช่น target_location)
--   6. reason / description        (หมายเหตุ)
--   7. lang / device / user_id     (context สำหรับ logging และ i18n)
--   8. OUTPUT params               (error_code, error_message)
-- ============================================================
CREATE OR ALTER PROCEDURE [inv].[usp_inventory_putaway]
    -- ── 1. ตัวระบุ record หลัก ──────────────────────────────
    @in_int_inventory_id            BIGINT         = NULL,     -- Source inventory_id ที่ต้องการย้าย (NULL = ค้นหาจาก item/location)

    -- ── 2. Lookup fallback (ใช้เมื่อ inventory_id เป็น NULL) ─
    @in_vch_item_number             NVARCHAR(50)   = NULL,     -- Item number สำหรับค้นหา inventory
    @in_vch_location                NVARCHAR(50)   = NULL,     -- Location สำหรับค้นหา inventory

    -- ── 3. Lot & Expiry Control ───────────────────────────────
    @in_vch_lot_number              NVARCHAR(50)   = NULL,     -- Lot number (จำเป็นเมื่อ lot_control = 'FULL')
    @in_dat_expiry_date             DATE           = NULL,     -- Expiry date (จำเป็นเมื่อ expiry_date_control = 'FULL')

    -- ── 4. Serial Control ─────────────────────────────────────
    @in_vch_serial_number           NVARCHAR(50)   = NULL,     -- Serial number ที่ต้องการย้ายเฉพาะตัว (NULL = ย้ายทุก serial)

    -- ── 5. Operation-specific Parameters ─────────────────────
    @in_dec_qty                     DECIMAL(18, 4),            -- จำนวนที่ต้องการย้าย (รองรับ partial put away)
    @in_int_target_location_id      INT,                       -- Location ID ปลายทางที่ต้องการย้ายไป

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
        -- Source Location
        @v_int_source_location_id       INT,
        @v_vch_source_location          NVARCHAR(50),
        -- Target Location
        @v_vch_target_location          NVARCHAR(50),
        @v_int_target_inventory_id      BIGINT,
        -- Item
        @v_int_item_master_id           INT,
        @v_vch_item_number              NVARCHAR(50),
        @v_vch_item_description         NVARCHAR(200),
        -- UOM
        @v_int_item_uom_id              INT,
        @v_vch_uom                      NVARCHAR(10),
        -- Inventory Detail
        @v_dec_source_qty               DECIMAL(18, 4),
        @v_vch_inv_status               NVARCHAR(50),
        @v_dat_receive_date             DATE,
        @v_vch_lot_number               NVARCHAR(50),
        @v_dat_expiry_date              DATE,
        -- Serial
        @v_int_serial_count             INT,
        -- Process Tracking
        @v_dt_process_start             DATETIME = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================================
        -- STEP 0: Auto-resolve inventory_id
        --         ถ้าไม่ได้ส่ง inventory_id มา → ค้นหาจาก item_number + location + lot + expiry
        -- ============================================================
        IF @in_int_inventory_id IS NULL
        BEGIN
            -- หา default warehouse (active, เก่าสุด)
            SELECT TOP 1
                @v_int_warehouse_id = warehouse_id,
                @v_vch_warehouse    = warehouse
            FROM [inv].[t_inv_warehouse]
            WHERE is_active = 1
            ORDER BY create_date ASC;

            -- หา default owner (active, เก่าสุด)
            SELECT TOP 1
                @v_int_owner_id   = owner_id,
                @v_vch_owner_code = owner_code
            FROM [inv].[t_inv_owner]
            WHERE is_active = 1
            ORDER BY create_date ASC;

            -- ค้นหา inventory_id จาก key ที่รับมา
            SELECT TOP 1
                @in_int_inventory_id = inventory_id
            FROM [inv].[t_inv_inventory]
            WHERE item_number                           = ISNULL(@in_vch_item_number, item_number)
              AND location                              = ISNULL(@in_vch_location, location)
              AND ISNULL(lot_number,   '')              = ISNULL(@in_vch_lot_number,    '')
              AND ISNULL(expiry_date,  '1900-01-01')    = ISNULL(@in_dat_expiry_date,   '1900-01-01')
              AND ISNULL(inv_status,   '')              = ISNULL(@v_vch_inv_status,     '')
            ORDER BY inventory_id ASC;
        END

        -- ============================================================
        -- STEP 1: ดึงข้อมูล Source Inventory
        -- ============================================================
        SELECT
            @v_int_warehouse_id         = inv.warehouse_id,
            @v_vch_warehouse            = inv.warehouse,
            @v_int_owner_id             = inv.owner_id,
            @v_vch_owner_code           = inv.owner_code,
            @v_int_source_location_id   = inv.location_id,
            @v_vch_source_location      = inv.location,
            @v_int_item_master_id       = inv.item_master_id,
            @v_vch_item_number          = inv.item_number,
            @v_vch_item_description     = inv.item_description,
            @v_dec_source_qty           = inv.quantity,
            @v_vch_inv_status           = inv.inv_status,
            @v_dat_receive_date         = inv.receive_date,
            @v_vch_lot_number           = inv.lot_number,
            @v_dat_expiry_date          = inv.expiry_date
        FROM [inv].[t_inv_inventory] inv
        WHERE inv.inventory_id = @in_int_inventory_id;

        -- ดึง UOM หลักของ item
        SELECT TOP 1
            @v_int_item_uom_id = iuom.item_uom_id,
            @v_vch_uom         = iuom.uom
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_master_id = @v_int_item_master_id
          AND iuom.primary_uom    = 1;

        -- ดึงชื่อ Target Location
        SELECT @v_vch_target_location = loc.location
        FROM [inv].[t_inv_location] loc
        WHERE loc.location_id = @in_int_target_location_id;

        -- ============================================================
        -- STEP 2: Validation
        -- ============================================================
        SELECT @v_vch_error_code = CASE
            WHEN @v_int_item_master_id IS NULL
                THEN 'ERR_INVENTORY_NOT_FOUND'          -- ไม่พบ source inventory
            WHEN @v_vch_target_location IS NULL
                THEN 'ERR_LOCATION_NOT_FOUND'           -- ไม่พบ target location
            WHEN @in_int_target_location_id = @v_int_source_location_id
                THEN 'ERR_SAME_LOCATION'                -- ห้ามย้ายไป location เดิม
            WHEN @in_dec_qty <= 0
                THEN 'ERR_INVALID_QTY'                  -- จำนวนต้องมากกว่า 0
            WHEN @in_dec_qty > @v_dec_source_qty
                THEN 'ERR_QTY_EXCEEDS_AVAILABLE'        -- จำนวนเกิน qty คงเหลือ
            ELSE 'SUCCESS'
        END;

        -- ตรวจ serial ที่ระบุมาว่ามีอยู่ใน source จริงหรือไม่
        IF @in_vch_serial_number IS NOT NULL AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_count = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            WHERE invs.inventory_id  = @in_int_inventory_id
              AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_count = 0
                SET @v_vch_error_code = 'ERR_SERIAL_NOT_FOUND';  -- Serial ที่ระบุไม่มีใน source
        END

        -- หยุดทำงานและ return error ถ้า validation ไม่ผ่าน
        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE', @out_vch_error_code, @in_vch_lang, '@param1', '@param2', '@param3', '@param4', '@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- ============================================================
        -- STEP 3: ลด qty ที่ Source Inventory
        -- ============================================================
        UPDATE [inv].[t_inv_inventory]
        SET quantity    = quantity - @in_dec_qty,
            update_by   = @in_vch_user_id,
            update_date = GETDATE()
        WHERE inventory_id = @in_int_inventory_id;

        -- ถ้า qty เหลือ 0 → ลบ source inventory row
        -- (serial จะถูก reassign ใน STEP 5 ก่อนที่ row นี้ถูกลบผ่าน FK cascade หรือหลัง reassign)
        IF (@v_dec_source_qty - @in_dec_qty) = 0
        BEGIN
            DELETE FROM [inv].[t_inv_inventory]
            WHERE inventory_id = @in_int_inventory_id;
        END

        -- ============================================================
        -- STEP 4: MERGE เข้า Target Inventory
        --         ถ้ามี record ที่ตรงกัน (warehouse+owner+location+item+status+lot+expiry+receive_date) → UPDATE qty
        --         ถ้าไม่มี → INSERT record ใหม่
        -- ============================================================
        MERGE [inv].[t_inv_inventory] AS target
        USING (
            SELECT
                @v_int_warehouse_id        AS warehouse_id,
                @v_vch_warehouse           AS warehouse,
                @v_int_owner_id            AS owner_id,
                @v_vch_owner_code          AS owner_code,
                @in_int_target_location_id AS location_id,
                @v_vch_target_location     AS location,
                @v_int_item_master_id      AS item_master_id,
                @v_vch_item_number         AS item_number,
                @v_vch_item_description    AS item_description,
                @v_vch_inv_status          AS inv_status,
                @v_dat_receive_date        AS receive_date,
                @v_vch_lot_number          AS lot_number,
                @v_dat_expiry_date         AS expiry_date
        ) AS source
        ON  target.warehouse_id                          = source.warehouse_id
            AND target.owner_id                          = source.owner_id
            AND target.location_id                       = source.location_id
            AND target.item_master_id                    = source.item_master_id
            AND ISNULL(target.inv_status,   '')          = ISNULL(source.inv_status,   '')
            AND ISNULL(target.lot_number,   '')          = ISNULL(source.lot_number,   '')
            AND ISNULL(target.expiry_date,  '1900-01-01') = ISNULL(source.expiry_date,  '1900-01-01')
            AND ISNULL(target.receive_date, '1900-01-01') = ISNULL(source.receive_date, '1900-01-01')
        WHEN MATCHED THEN
            UPDATE SET
                quantity    = ISNULL(target.quantity, 0) + @in_dec_qty,
                update_by   = @in_vch_user_id,
                update_date = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (
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
                receive_date,
                lot_number,
                expiry_date,
                create_by,
                create_date
            )
            VALUES (
                source.warehouse_id,
                source.warehouse,
                source.owner_id,
                source.owner_code,
                source.location_id,
                source.location,
                source.item_master_id,
                source.item_number,
                source.item_description,
                @in_dec_qty,
                source.inv_status,
                source.receive_date,
                source.lot_number,
                source.expiry_date,
                @in_vch_user_id,
                GETDATE()
            );

        -- ============================================================
        -- STEP 5: ย้าย Serial ไปชี้ Target Inventory
        --         (ทำเมื่อมี serial อยู่ใน source หรือระบุ serial มาโดยตรง)
        -- ============================================================
        IF @in_vch_serial_number IS NOT NULL OR EXISTS (
            SELECT 1 FROM [inv].[t_inv_inventory_serial]
            WHERE inventory_id = @in_int_inventory_id
        )
        BEGIN
            -- ดึง target inventory_id ที่เพิ่ง INSERT/UPDATE จาก STEP 4
            SELECT @v_int_target_inventory_id = inv.inventory_id
            FROM [inv].[t_inv_inventory] inv
            WHERE inv.warehouse_id                         = @v_int_warehouse_id
              AND inv.owner_id                             = @v_int_owner_id
              AND inv.location_id                          = @in_int_target_location_id
              AND inv.item_master_id                       = @v_int_item_master_id
              AND ISNULL(inv.inv_status,   '')             = ISNULL(@v_vch_inv_status,   '')
              AND ISNULL(inv.lot_number,   '')             = ISNULL(@v_vch_lot_number,   '')
              AND ISNULL(inv.expiry_date,  '1900-01-01')   = ISNULL(@v_dat_expiry_date,  '1900-01-01')
              AND ISNULL(inv.receive_date, '1900-01-01')   = ISNULL(@v_dat_receive_date, '1900-01-01');

            -- Reassign serial: ชี้ inventory_id จาก source → target
            -- ถ้าระบุ serial เฉพาะตัว → ย้ายแค่ตัวนั้น
            -- ถ้าไม่ระบุ (NULL) → ย้ายทุก serial ใน source inventory
            UPDATE [inv].[t_inv_inventory_serial]
            SET inventory_id = @v_int_target_inventory_id,
                update_by    = @in_vch_user_id,
                update_date  = GETDATE()
            WHERE inventory_id = @in_int_inventory_id
              AND (
                    @in_vch_serial_number IS NULL
                    OR serial_number = @in_vch_serial_number
                  );
        END

        -- ============================================================
        -- STEP 6: บันทึก Transaction Log
        -- ============================================================
        INSERT INTO [inv].[t_inv_tran_log] (
            tran_type,
            -- ประเภทธุรกรรมหลัก
            sub_tran_type,
            -- ประเภทธุรกรรมย่อย
            warehouse_id,
            warehouse,
            owner_id,
            owner_code,
            location_id,
            -- Source location
            location,
            after_location_id,
            -- Target location (หลังย้าย)
            after_location,
            item_master_id,
            item_number,
            item_description,
            quantity,
            item_uom_id,
            uom,
            inv_status,
            after_inv_status,
            receive_date,
            lot_number,
            after_lot_number,
            expiry_date,
            after_expiry_date,
            serial_number,
            device,
            create_by,
            create_date
        )
        VALUES (
            'PUT_AWAY',
            'PUT_AWAY',
            @v_int_warehouse_id,
            @v_vch_warehouse,
            @v_int_owner_id,
            @v_vch_owner_code,
            @v_int_source_location_id,
            -- location ก่อนย้าย
            @v_vch_source_location,
            @in_int_target_location_id,
            -- location หลังย้าย
            @v_vch_target_location,
            @v_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @in_dec_qty,
            @v_int_item_uom_id,
            @v_vch_uom,
            @v_vch_inv_status,
            @v_vch_inv_status,
            -- inv_status ไม่เปลี่ยน ณ PUT_AWAY
            @v_dat_receive_date,
            @v_vch_lot_number,
            @v_vch_lot_number,
            -- lot ไม่เปลี่ยน
            @v_dat_expiry_date,
            @v_dat_expiry_date,
            -- expiry ไม่เปลี่ยน
            @in_vch_serial_number,
            @in_vch_device,
            @in_vch_user_id,
            GETDATE()
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
            ,@in_vch_process         = 'usp_inventory_putaway'   -- [FIX] แก้ชื่อ process ให้ตรงกับ SP จริง
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = @out_vch_error_code
            ,@out_vch_error_message  = @out_vch_error_message
            ,@in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
