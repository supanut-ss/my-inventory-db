USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inventory_adjustment]
-- Purpose : ปรับยอด inventory เพิ่ม (ADJUST_IN) หรือลด (ADJUST_OUT)
--           รองรับ Lot / Expiry / Serial Control
-- ============================================================
-- PARAMETER CONVENTIONS (เรียงลำดับเหมือนกันทุก Stored Procedure)
--   1. inventory_id / lookup keys  (ตัวระบุ record หลัก)
--   2. item_number / location      (lookup fallback)
--   3. lot_number / expiry_date    (lot & expiry control)
--   4. serial_number               (serial control)
--   5. operation-specific params   (เฉพาะ SP นี้ เช่น adj_type, qty)
--   6. reason / description        (หมายเหตุ)
--   7. lang / device / user_id     (context สำหรับ logging และ i18n)
--   8. OUTPUT params               (error_code, error_message)
-- ============================================================
ALTER PROCEDURE [inv].[usp_inventory_adjustment]
    -- ── 1. ตัวระบุ record หลัก ──────────────────────────────
    @in_int_inventory_id            BIGINT         = NULL,     -- inventory_id ที่ต้องการปรับ (NULL = ค้นหาจาก item/location)

    -- ── 2. Lookup fallback (ใช้เมื่อ inventory_id เป็น NULL) ─
    @in_vch_item_number             NVARCHAR(50)   = NULL,     -- Item number สำหรับค้นหา inventory
    @in_vch_location                NVARCHAR(50)   = NULL,     -- Location สำหรับค้นหา inventory

    -- ── 3. Lot & Expiry Control ───────────────────────────────
    @in_vch_lot_number              NVARCHAR(50)   = NULL,     -- Lot number (จำเป็นเมื่อ lot_control = 'FULL')
    @in_dt_expiry_date             DATE           = NULL,     -- Expiry date (จำเป็นเมื่อ expiry_date_control = 'FULL')

    -- ── 4. Serial Control ─────────────────────────────────────
    @in_vch_serial_number           NVARCHAR(50)   = NULL,     -- Serial number (จำเป็นเมื่อ sn_control = 'FULL')

    -- ── 5. Operation-specific Parameters ─────────────────────
    @in_vch_adj_type                VARCHAR(10),               -- ประเภทการปรับ: 'ADJUST_IN' (เพิ่ม) | 'ADJUST_OUT' (ลด)
    @in_dec_qty                     DECIMAL(18, 4),            -- จำนวนที่ต้องการปรับ (ต้องมากกว่า 0)

    -- ── 6. Remark / Description ───────────────────────────────
    @in_vch_remark                  NVARCHAR(200)  = NULL,     -- หมายเหตุการปรับ (บันทึกใน tran_log)

    -- ── 7. Context: Lang / Device / User ─────────────────────
    @in_vch_lang                    VARCHAR(20),               -- รหัสภาษาสำหรับ error message (เช่น 'TH', 'EN')
    @in_vch_device                  NVARCHAR(50)   = NULL,     -- Device ที่ทำรายการ (สำหรับ log)
    @in_vch_user_id                 NVARCHAR(50),              -- User ที่ทำรายการ

    -- ── 8. Output Parameters ──────────────────────────────────
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
        -- Inventory Detail
        @v_dec_current_qty              DECIMAL(18, 4),
        @v_dec_available_qty            DECIMAL(18, 4),
        @v_dec_remaining_qty            DECIMAL(18, 4),
        @v_dec_adjust_qty               DECIMAL(18, 4),
        @v_int_current_inventory_id     BIGINT,
        @v_dec_current_row_qty          DECIMAL(18, 4),
        @v_dt_current_receive_date     DATE,
        @v_vch_inv_status               NVARCHAR(50)  = 'Available',
        @v_dt_receive_date             DATE,
        -- Item Control Flags
        @v_vch_lot_control              VARCHAR(10),
        @v_vch_expiry_control           VARCHAR(10),
        @v_vch_sn_control               VARCHAR(10),
        -- Serial
        @v_int_serial_exists            INT,
        -- Process Tracking
        @v_dt_process_start             DATETIME      = GETDATE();

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
            ORDER BY warehouse_id ASC;

            -- หา default owner (active, เก่าสุด)
            SELECT TOP 1
                @v_int_owner_id   = owner_id,
                @v_vch_owner_code = owner_code
            FROM [inv].[t_inv_owner]
            WHERE is_active = 1
            ORDER BY owner_id ASC;

            -- ค้นหา inventory_id จาก key ที่รับมา
            SELECT TOP 1
                @in_int_inventory_id = inventory_id
            FROM [inv].[t_inv_inventory]
            WHERE item_number                           = ISNULL(@in_vch_item_number, item_number)
              AND location                              = ISNULL(@in_vch_location, location)
              AND ISNULL(lot_number,   '')              = ISNULL(@in_vch_lot_number,    '')
              AND ISNULL(expiry_date,  '')              = ISNULL(@in_dt_expiry_date,   '')
              AND ISNULL(inv_status,   '')              = ISNULL(@v_vch_inv_status,     '')
            ORDER BY
                receive_date ASC,
                inventory_id ASC;
        END

        -- ============================================================
        -- STEP 1: ดึงข้อมูล Inventory
        -- ============================================================
        SELECT
            @v_int_warehouse_id     = inv.warehouse_id,
            @v_vch_warehouse        = inv.warehouse,
            @v_int_owner_id         = inv.owner_id,
            @v_vch_owner_code       = inv.owner_code,
            @v_int_location_id      = inv.location_id,
            @v_vch_location         = inv.location,
            @v_int_item_master_id   = inv.item_master_id,
            @v_vch_item_number      = inv.item_number,
            @v_vch_item_description = inv.item_description,
            @v_dec_current_qty      = inv.quantity,
            @v_vch_inv_status       = inv.inv_status,
            @v_dt_receive_date     = inv.receive_date
        FROM [inv].[t_inv_inventory] inv
        WHERE inv.inventory_id = @in_int_inventory_id;

        -- Fallback: ถ้าไม่พบ inventory ให้ใช้ค่า input แทน
        SET @v_vch_item_number = ISNULL(@v_vch_item_number, @in_vch_item_number);
        SET @v_vch_location    = ISNULL(@v_vch_location,    @in_vch_location);

        -- ดึงข้อมูล item จาก item_master (ถ้าพบ)
        IF @v_int_item_master_id IS NOT NULL
        BEGIN
            SELECT
                @v_vch_item_number      = itm.item_number,
                @v_vch_item_description = itm.description
            FROM [inv].[t_inv_item] itm
            WHERE itm.item_master_id = @v_int_item_master_id;
        END

        -- ดึง Item Control Flags (lot / expiry / serial)
        SELECT
            @v_vch_lot_control    = itm.lot_control,
            @v_vch_expiry_control = itm.expiry_date_control,
            @v_vch_sn_control     = itm.sn_control
        FROM [inv].[t_inv_item] itm
        WHERE itm.item_master_id = @v_int_item_master_id;

        -- ดึง UOM หลักของ item
        SELECT TOP 1
            @v_int_item_uom_id = iuom.item_uom_id,
            @v_vch_uom         = iuom.uom
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_master_id = @v_int_item_master_id
          AND iuom.primary_uom    = 1;

        IF @in_vch_adj_type = 'ADJUST_OUT'
        BEGIN
            SELECT
                @v_dec_available_qty = ISNULL(SUM(inv.quantity), 0)
            FROM [inv].[t_inv_inventory] inv
            WHERE inv.warehouse_id    = @v_int_warehouse_id
              AND inv.owner_id        = @v_int_owner_id
              AND inv.location_id     = @v_int_location_id
              AND inv.item_master_id  = @v_int_item_master_id
              AND ISNULL(inv.inv_status,  '')           = ISNULL(@v_vch_inv_status,  '')
              AND ISNULL(inv.lot_number,  '')           = ISNULL(@in_vch_lot_number, '')
              AND ISNULL(inv.expiry_date, '')           = ISNULL(@in_dt_expiry_date, '')
              AND (
                    @v_vch_sn_control <> 'FULL'
                    OR @in_vch_serial_number IS NULL
                    OR EXISTS (
                        SELECT 1
                        FROM [inv].[t_inv_inventory_serial] invs
                        WHERE invs.inventory_id  = inv.inventory_id
                          AND invs.serial_number = @in_vch_serial_number
                    )
                  );
        END
        ELSE
        BEGIN
            SET @v_dec_available_qty = @v_dec_current_qty;
        END

        -- ============================================================
        -- STEP 2: Validation
        -- ============================================================
        SELECT @v_vch_error_code = CASE
            WHEN @v_int_item_master_id IS NULL
                THEN 'ERR_INVENTORY_NOT_FOUND'              -- ไม่พบ inventory
            WHEN @in_vch_adj_type NOT IN ('ADJUST_IN', 'ADJUST_OUT')
                THEN 'ERR_INVALID_ADJ_TYPE'                 -- adj_type ไม่ถูกต้อง
            WHEN @in_dec_qty <= 0
                THEN 'ERR_INVALID_QTY'                      -- จำนวนต้องมากกว่า 0
            WHEN @in_vch_adj_type = 'ADJUST_OUT' AND @in_dec_qty > ISNULL(@v_dec_available_qty, 0)
                THEN 'ERR_QTY_EXCEEDS_AVAILABLE'            -- ADJUST_OUT เกิน qty คงเหลือ
            WHEN @v_vch_lot_control = 'FULL' AND ISNULL(@in_vch_lot_number, '') = ''
                THEN 'ERR_LOT_REQUIRED'                     -- item ต้องการ lot แต่ไม่ได้ส่งมา
            WHEN @v_vch_lot_control = 'NONE' AND ISNULL(@in_vch_lot_number, '') <> ''
                THEN 'ERR_LOT_MUST_BE_EMPTY'                -- item ไม่ใช้ lot แต่ส่ง lot มา
            WHEN @v_vch_expiry_control = 'FULL' AND @in_dt_expiry_date IS NULL
                THEN 'ERR_EXPIRY_REQUIRED'                  -- item ต้องการ expiry แต่ไม่ได้ส่งมา
            WHEN @v_vch_expiry_control = 'NONE' AND @in_dt_expiry_date IS NOT NULL
                THEN 'ERR_EXPIRY_MUST_BE_EMPTY'             -- item ไม่ใช้ expiry แต่ส่ง expiry มา
            WHEN @v_vch_sn_control = 'FULL' AND ISNULL(@in_vch_serial_number, '') = ''
                THEN 'ERR_SERIAL_REQUIRED'                  -- item ต้องการ serial แต่ไม่ได้ส่งมา
            WHEN @v_vch_sn_control = 'NONE' AND ISNULL(@in_vch_serial_number, '') <> ''
                THEN 'ERR_SERIAL_MUST_BE_EMPTY'             -- item ไม่ใช้ serial แต่ส่ง serial มา
            ELSE 'SUCCESS'
        END;

        -- ตรวจ serial ซ้ำสำหรับ ADJUST_IN (serial ต้องไม่มีในระบบ)
        IF @v_vch_sn_control = 'FULL'
            AND @in_vch_adj_type = 'ADJUST_IN'
            AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            INNER JOIN [inv].[t_inv_inventory] inv
                ON invs.inventory_id = inv.inventory_id
            WHERE inv.item_master_id   = @v_int_item_master_id
              AND invs.serial_number   = @in_vch_serial_number;

            IF @v_int_serial_exists > 0
                SET @v_vch_error_code = 'ERR_SERIAL_DUPLICATE';  -- Serial นี้มีในระบบแล้ว
        END

        IF @v_vch_sn_control = 'FULL'
            AND @in_vch_adj_type = 'ADJUST_OUT'
            AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            INNER JOIN [inv].[t_inv_inventory] inv
                ON inv.inventory_id = invs.inventory_id
            WHERE inv.warehouse_id    = @v_int_warehouse_id
              AND inv.owner_id        = @v_int_owner_id
              AND inv.location_id     = @v_int_location_id
              AND inv.item_master_id  = @v_int_item_master_id
              AND ISNULL(inv.inv_status,  '')           = ISNULL(@v_vch_inv_status,  '')
              AND ISNULL(inv.lot_number,  '')           = ISNULL(@in_vch_lot_number, '')
              AND ISNULL(inv.expiry_date, '')           = ISNULL(@in_dt_expiry_date, '')
              AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists = 0
                SET @v_vch_error_code = 'ERR_SERIAL_NOT_FOUND';  -- ไม่พบ serial ใน inventory นี้
        END

        -- หยุดทำงานและ return error ถ้า validation ไม่ผ่าน
        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE', @out_vch_error_code, @in_vch_lang, '@param1', '@param2', '@param3', '@param4', '@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- ============================================================
        -- STEP 3: ปรับยอด Inventory
        -- ============================================================
        IF @in_vch_adj_type = 'ADJUST_IN'
        BEGIN
            UPDATE [inv].[t_inv_inventory]
            SET quantity    = quantity + @in_dec_qty,
                update_by   = @in_vch_user_id,
                update_date = GETDATE()
            WHERE inventory_id = @in_int_inventory_id;
        END
        ELSE
        BEGIN
            SET @v_dt_receive_date  = NULL;
            SET @v_dec_remaining_qty = @in_dec_qty;

            WHILE @v_dec_remaining_qty > 0
            BEGIN
                SET @v_int_current_inventory_id = NULL;

                SELECT TOP 1
                    @v_int_current_inventory_id = inv.inventory_id,
                    @v_dec_current_row_qty      = inv.quantity,
                    @v_dt_current_receive_date = inv.receive_date
                FROM [inv].[t_inv_inventory] inv
                WHERE inv.warehouse_id    = @v_int_warehouse_id
                  AND inv.owner_id        = @v_int_owner_id
                  AND inv.location_id     = @v_int_location_id
                  AND inv.item_master_id  = @v_int_item_master_id
                  AND inv.quantity        > 0
                  AND ISNULL(inv.inv_status,  '')           = ISNULL(@v_vch_inv_status,  '')
                  AND ISNULL(inv.lot_number,  '')           = ISNULL(@in_vch_lot_number, '')
                  AND ISNULL(inv.expiry_date, '')           = ISNULL(@in_dt_expiry_date, '')
                  AND (
                        @v_vch_sn_control <> 'FULL'
                        OR @in_vch_serial_number IS NULL
                        OR EXISTS (
                            SELECT 1
                            FROM [inv].[t_inv_inventory_serial] invs
                            WHERE invs.inventory_id  = inv.inventory_id
                              AND invs.serial_number = @in_vch_serial_number
                        )
                      )
                ORDER BY
                    inv.receive_date ASC,
                    inv.inventory_id ASC;

                IF @v_int_current_inventory_id IS NULL
                BEGIN
                    SET @v_vch_error_code = 'ERR_QTY_EXCEEDS_AVAILABLE';
                    SET @out_vch_error_code    = @v_vch_error_code;
                    SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE', @out_vch_error_code, @in_vch_lang, '@param1', '@param2', '@param3', '@param4', '@param5');
                    RAISERROR(@out_vch_error_message, 16, 1);
                END

                SET @v_dec_adjust_qty = CASE
                    WHEN @v_dec_current_row_qty >= @v_dec_remaining_qty
                        THEN @v_dec_remaining_qty
                    ELSE @v_dec_current_row_qty
                END;

                UPDATE [inv].[t_inv_inventory]
                SET quantity    = quantity - @v_dec_adjust_qty,
                    update_by   = @in_vch_user_id,
                    update_date = GETDATE()
                WHERE inventory_id = @v_int_current_inventory_id;

                IF @v_vch_sn_control = 'FULL'
                BEGIN
                    DELETE FROM [inv].[t_inv_inventory_serial]
                    WHERE inventory_id  = @v_int_current_inventory_id
                      AND serial_number = @in_vch_serial_number;
                END

                IF (@v_dec_current_row_qty - @v_dec_adjust_qty) = 0
                BEGIN
                    DELETE FROM [inv].[t_inv_inventory_serial]
                    WHERE inventory_id = @v_int_current_inventory_id;

                    DELETE FROM [inv].[t_inv_inventory]
                    WHERE inventory_id = @v_int_current_inventory_id;
                END

                IF @v_dt_receive_date IS NULL
                    SET @v_dt_receive_date = @v_dt_current_receive_date;

                SET @v_dec_remaining_qty = @v_dec_remaining_qty - @v_dec_adjust_qty;
            END
        END

        -- ============================================================
        -- STEP 4: จัดการ Serial
        -- ============================================================
        IF @v_vch_sn_control = 'FULL'
            AND @in_vch_adj_type = 'ADJUST_IN'
        BEGIN
            IF @in_vch_adj_type = 'ADJUST_IN'
            BEGIN
                -- เพิ่ม serial ใหม่เข้าระบบ
                INSERT INTO [inv].[t_inv_inventory_serial] (
                    inventory_id,
                    serial_number,
                    create_by,
                    create_date
                )
                VALUES (
                    @in_int_inventory_id,
                    @in_vch_serial_number,
                    @in_vch_user_id,
                    GETDATE()
                );
            END
        END

        -- ============================================================
        -- STEP 5: บันทึก Transaction Log
        -- ============================================================
        INSERT INTO [inv].[t_inv_tran_log] (
            tran_type,
            -- ประเภทธุรกรรมหลัก
            sub_tran_type,
            -- ประเภทธุรกรรมย่อย (ADJUST_IN / ADJUST_OUT)
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
            @in_vch_adj_type,
            'Inventory adjustment',
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
            @v_vch_inv_status,
            @v_vch_inv_status,
            -- status ไม่เปลี่ยน
            @v_dt_receive_date,
            @in_vch_lot_number,
            @in_vch_lot_number,
            -- lot ไม่เปลี่ยน
            @in_dt_expiry_date,
            @in_dt_expiry_date,
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
            ,@in_vch_process         = 'usp_inventory_adjustment'
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = @out_vch_error_code
            ,@out_vch_error_message  = @out_vch_error_message
            ,@in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
