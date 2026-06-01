USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_count_reconcile]
-- ============================================================
-- This stored procedure [inv].[usp_count_reconcile] is designed to reconcile inventory count details
-- and update or insert records into both [t_inv_count_detail] and [t_inv_count_reconcile] tables.
-- It performs validation, handles error messaging via resource lookup, and logs process results.
-- The procedure supports multi-language error messages and ensures transactional integrity.
-- ============================================================
-- PARAMETER CONVENTIONS
--   1. count_master_id / count_number  (ตัวระบุ count master)
--   2. location_id / location          (lookup fallback)
--   3. item_master_id / item_number    (lookup fallback)
--   4. operation-specific params       (qty, inv_status, lot, expiry, serial)
--   5. lang / device / user_id         (context)
--   6. OUTPUT params                   (error_code, error_message)
-- ============================================================

CREATE OR ALTER PROCEDURE [inv].[usp_count_reconcile]
    -- ── 1. Count Master ──────────────────────────────────────
    @in_int_count_master_id     BIGINT         = NULL,  -- Count master ID (NULL = ค้นหาจาก count_number)
    @in_vch_count_number        NVARCHAR(50)   = NULL,  -- Count number (ใช้เมื่อไม่มี count_master_id)

    -- ── 2. Location ──────────────────────────────────────────
    @in_int_location_id         INT            = NULL,  -- Location ID (NULL = ค้นหาจาก location code)
    @in_vch_location            NVARCHAR(50)   = NULL,  -- Location code (ใช้เมื่อไม่มี location_id)

    -- ── 3. Item ──────────────────────────────────────────────
    @in_int_item_master_id      INT            = NULL,  -- Item master ID (NULL = ค้นหาจาก item_number หรือ cross_ref)
    @in_vch_item_number         NVARCHAR(50)   = NULL,  -- Item number (ใช้เมื่อไม่มี item_master_id)

    -- ── 4. Operation-specific Parameters ─────────────────────
    @in_dec_quantity_count      DECIMAL(18, 4),
    @in_vch_inv_status          NVARCHAR(50)   = NULL,
    @in_vch_lot_number          NVARCHAR(50)   = NULL,
    @in_dt_expiry_date          DATE           = NULL,
    @in_vch_serial_number       NVARCHAR(50)   = NULL,

    -- ── 5. Context: Lang / Device / User ─────────────────────
    @in_vch_lang                VARCHAR(20),
    @in_vch_user_id             NVARCHAR(50),
    @in_vch_device              NVARCHAR(50)   = NULL,

    -- ── 6. Output Parameters ──────────────────────────────────
    @out_vch_error_code         VARCHAR(50)    OUTPUT,
    @out_vch_error_message      NVARCHAR(255)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Declare local variables for process control and data retrieval
    DECLARE
        @v_vch_error_code           VARCHAR(50),
        @v_vch_error_message        NVARCHAR(255),
        @v_vch_close_by             NVARCHAR(50),
        @v_int_warehouse_id         INT,
        @v_vch_warehouse            NVARCHAR(50),
        @v_int_owner_id             INT,
        @v_vch_owner_code           NVARCHAR(50),
        @v_vch_location             NVARCHAR(50),
        @v_vch_item_number          NVARCHAR(50),
        @v_vch_item_description     NVARCHAR(200),
        @v_int_item_uom_id          INT,
        @v_vch_uom                  NVARCHAR(10),
        @v_int_count_detail_id      BIGINT,
        @v_int_count_reconcile_id   BIGINT,
        @v_dec_quantity_stock       DECIMAL(18, 4),
        @v_dt_receive_date          DATE,
        @v_vch_expiry_date_str      NVARCHAR(50),
        @v_dt_process_start         DATETIME = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================================
        -- STEP 0: Resolve count_master_id จาก count_number (ถ้าไม่ส่ง id มา)
        -- ============================================================
        IF @in_int_count_master_id IS NULL AND ISNULL(@in_vch_count_number, '') <> ''
        BEGIN
            SELECT TOP 1
                @in_int_count_master_id = count_master_id
            FROM [inv].[t_inv_count_master]
            WHERE count_number = @in_vch_count_number
            ORDER BY count_master_id DESC;
        END

        -- ============================================================
        -- STEP 1: Resolve location_id จาก location code (ถ้าไม่ส่ง id มา)
        -- ============================================================
        IF @in_int_location_id IS NULL AND ISNULL(@in_vch_location, '') <> ''
        BEGIN
            SELECT
                @in_int_location_id = location_id,
                @v_vch_location     = location
            FROM [inv].[t_inv_location]
            WHERE location   = @in_vch_location
              AND is_active  = 1;
        END
        ELSE
        BEGIN
            SELECT @v_vch_location = location
            FROM [inv].[t_inv_location]
            WHERE location_id = @in_int_location_id;
        END

        -- ============================================================
        -- STEP 2: Resolve item_master_id จาก item_number หรือ cross_ref
        -- ============================================================
        IF @in_int_item_master_id IS NULL
        BEGIN
            -- ลอง item_number ตรงๆ ก่อน
            IF ISNULL(@in_vch_item_number, '') <> ''
            BEGIN
                SELECT
                    @in_int_item_master_id  = item_master_id,
                    @v_vch_item_number      = item_number,
                    @v_vch_item_description = description
                FROM [inv].[t_inv_item]
                WHERE item_number = @in_vch_item_number
                  AND is_active   = 1;
            END

            -- ถ้าหา item_number ตรงไม่พบ → ลองหาจาก alternate_item_number ใน t_inv_item_cross_ref
            IF @in_int_item_master_id IS NULL AND ISNULL(@in_vch_item_number, '') <> ''
            BEGIN
                SELECT TOP 1
                    @in_int_item_master_id  = itm.item_master_id,
                    @v_vch_item_number      = itm.item_number,
                    @v_vch_item_description = itm.description
                FROM [inv].[t_inv_item] itm
                INNER JOIN [inv].[t_inv_item_cross_ref] xref
                    ON xref.item_master_id = itm.item_master_id
                WHERE xref.alternate_item_number = @in_vch_item_number
                  AND xref.is_active             = 1
                  AND itm.is_active              = 1
                ORDER BY itm.item_master_id ASC;
            END
        END
        ELSE
        BEGIN
            -- มี item_master_id แล้ว → ดึง item info
            SELECT
                @v_vch_item_number      = item_number,
                @v_vch_item_description = description
            FROM [inv].[t_inv_item]
            WHERE item_master_id = @in_int_item_master_id;
        END

        -- ============================================================
        -- STEP 3: Resolve Base UOM จาก item_master_id
        -- ============================================================
        SELECT TOP 1
            @v_int_item_uom_id = item_uom_id,
            @v_vch_uom         = uom
        FROM [inv].[t_inv_item_uom]
        WHERE item_master_id = @in_int_item_master_id
          AND primary_uom    = 1;

        -- ============================================================
        -- STEP 4: Retrieve count master information
        -- ============================================================
        SELECT
            @v_vch_close_by     = close_by,
            @v_int_warehouse_id = warehouse_id,
            @v_vch_warehouse    = warehouse,
            @v_int_owner_id     = owner_id,
            @v_vch_owner_code   = owner_code
        FROM [inv].[t_inv_count_master]
        WHERE count_master_id = @in_int_count_master_id;

        -- แปลง expiry date เป็น string format ISO (yyyy-mm-dd) สำหรับเก็บใน count_detail
        -- ใช้ format 23 เพื่อให้ตรงกับ column type ใน t_inv_count_detail ที่เก็บเป็น NVARCHAR
        SET @v_vch_expiry_date_str = CONVERT(NVARCHAR(50), @in_dt_expiry_date, 23);

        -- ============================================================
        -- STEP 5: Validation
        -- ============================================================
        SELECT @v_vch_error_code = CASE
            WHEN @in_int_count_master_id IS NULL   THEN 'ERR_COUNT_NUMBER_REQUIRED'
            WHEN @v_int_warehouse_id IS NULL        THEN 'ERR_COUNT_MASTER_NOT_FOUND'
            WHEN @v_vch_close_by IS NOT NULL        THEN 'ERR_COUNT_ALREADY_CLOSED'
            WHEN @in_int_location_id IS NULL        THEN 'ERR_LOCATION_REQUIRED'
            WHEN @v_vch_location IS NULL            THEN 'ERR_LOCATION_NOT_FOUND'
            WHEN @in_int_item_master_id IS NULL     THEN 'ERR_ITEM_REQUIRED'
            WHEN @v_vch_item_number IS NULL         THEN 'ERR_ITEM_NOT_FOUND'
            WHEN @v_vch_uom IS NULL                 THEN 'ERR_UOM_NOT_FOUND'
            WHEN @in_dec_quantity_count < 0         THEN 'ERR_INVALID_QTY'
            ELSE 'SUCCESS'
        END;

        -- หาก Validation ไม่ผ่าน ให้ set error output และ raise error
        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                'STORED_PROCEDURE',
                @out_vch_error_code,
                @in_vch_lang,
                '@param1','@param2','@param3','@param4','@param5'
            );
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- ============================================================
        -- STEP 6: Upsert count_detail
        -- ============================================================

        -- ตรวจหา count detail line ที่มีอยู่แล้ว
        -- หมายเหตุ: expiry_date ใน t_inv_count_detail เก็บเป็น NVARCHAR จึงเปรียบเทียบด้วย string
        SELECT
            @v_int_count_detail_id = count_detail_id,
            @v_dec_quantity_stock  = quantity_stock,
            @v_dt_receive_date     = receive_date
        FROM [inv].[t_inv_count_detail]
        WHERE count_master_id  = @in_int_count_master_id
            AND location_id    = @in_int_location_id
            AND item_master_id = @in_int_item_master_id
            AND ISNULL(inv_status,    '') = ISNULL(@in_vch_inv_status,     '')
            AND ISNULL(lot_number,    '') = ISNULL(@in_vch_lot_number,     '')
            AND ISNULL(expiry_date,   '') = ISNULL(@v_vch_expiry_date_str, '')
            AND ISNULL(serial_number, '') = ISNULL(@in_vch_serial_number,  '');

        -- Upsert count_detail: ถ้ามีอยู่แล้วให้ update จำนวน / ถ้าไม่มีให้ insert ใหม่
        IF @v_int_count_detail_id IS NOT NULL
        BEGIN
            -- อัปเดตจำนวนนับและข้อมูล audit trail
            UPDATE [inv].[t_inv_count_detail]
            SET
                quantity_count = @in_dec_quantity_count,
                count_by       = @in_vch_user_id,
                count_date     = GETDATE(),
                update_by      = @in_vch_user_id,
                update_date    = GETDATE()
            WHERE count_detail_id = @v_int_count_detail_id;
        END
        ELSE
        BEGIN
            -- ดึงจำนวน stock ปัจจุบันจาก inventory เพื่อเปรียบเทียบกับจำนวนที่นับได้
            SELECT @v_dec_quantity_stock = ISNULL(quantity, 0)
            FROM [inv].[t_inv_inventory]
            WHERE warehouse_id     = @v_int_warehouse_id
                AND owner_id       = @v_int_owner_id
                AND location_id    = @in_int_location_id
                AND item_master_id = @in_int_item_master_id
            AND ISNULL(inv_status,  '') = ISNULL(@in_vch_inv_status, '')
            AND ISNULL(lot_number,  '') = ISNULL(@in_vch_lot_number, '')
            AND ISNULL(expiry_date, '') = ISNULL(@in_dt_expiry_date, '');

            SET @v_dt_receive_date = CAST(GETDATE() AS DATE);

            -- Generate new count_detail_id จาก sequence
            SET @v_int_count_detail_id = NEXT VALUE FOR [inv].[SEQCountID];

            INSERT INTO [inv].[t_inv_count_detail] (
                count_detail_id,
                count_master_id,
                location_id,
                location,
                item_master_id,
                item_number,
                item_description,
                quantity_stock,
                quantity_count,
                item_uom_id,
                uom,
                inv_status,
                lot_number,
                expiry_date,
                serial_number,
                receive_date,
                count_by,
                count_date,
                create_by,
                create_date
            )
            VALUES (
                @v_int_count_detail_id,
                @in_int_count_master_id,
                @in_int_location_id,
                @v_vch_location,
                @in_int_item_master_id,
                @v_vch_item_number,
                @v_vch_item_description,
                ISNULL(@v_dec_quantity_stock, 0),
                @in_dec_quantity_count,
                @v_int_item_uom_id,
                @v_vch_uom,
                @in_vch_inv_status,
                @in_vch_lot_number,
                @v_vch_expiry_date_str,
                @in_vch_serial_number,
                @v_dt_receive_date,
                @in_vch_user_id,
                GETDATE(),
                @in_vch_user_id,
                GETDATE()
            );
        END

        -- ============================================================
        -- STEP 7: Upsert count_reconcile
        -- ============================================================

        SELECT @v_int_count_reconcile_id = count_reconcile_id
        FROM [inv].[t_inv_count_reconcile]
        WHERE count_master_id  = @in_int_count_master_id
            AND location_id    = @in_int_location_id
            AND item_master_id = @in_int_item_master_id
            AND ISNULL(inv_status,    '') = ISNULL(@in_vch_inv_status,     '')
            AND ISNULL(lot_number,    '') = ISNULL(@in_vch_lot_number,     '')
            AND ISNULL(expiry_date,   '') = ISNULL(@v_vch_expiry_date_str, '')
            AND ISNULL(serial_number, '') = ISNULL(@in_vch_serial_number,  '');

        IF @v_int_count_reconcile_id IS NOT NULL
        BEGIN
            UPDATE [inv].[t_inv_count_reconcile]
            SET
                quantity_count = @in_dec_quantity_count,
                update_by      = @in_vch_user_id,
                update_date    = GETDATE()
            WHERE count_reconcile_id = @v_int_count_reconcile_id;
        END
        ELSE
        BEGIN
            INSERT INTO [inv].[t_inv_count_reconcile] (
                count_master_id,
                location_id,
                location,
                item_master_id,
                item_number,
                item_description,
                quantity_count,
                item_uom_id,
                uom,
                inv_status,
                lot_number,
                expiry_date,
                serial_number,
                receive_date,
                create_by,
                create_date
            )
            VALUES (
                @in_int_count_master_id,
                @in_int_location_id,
                @v_vch_location,
                @in_int_item_master_id,
                @v_vch_item_number,
                @v_vch_item_description,
                @in_dec_quantity_count,
                @v_int_item_uom_id,
                @v_vch_uom,
                @in_vch_inv_status,
                @in_vch_lot_number,
                @v_vch_expiry_date_str,
                @in_vch_serial_number,
                @v_dt_receive_date,
                @in_vch_user_id,
                GETDATE()
            );
        END

        -- Commit transaction และ set success output
        COMMIT TRANSACTION;
        SET @out_vch_error_code    = '0';
        SET @out_vch_error_message = [sec].usf_get_resouce_value(
            'STORED_PROCEDURE',
            'SAVE_SUCCESS',
            @in_vch_lang,
            '@param1','@param2','@param3','@param4','@param5'
        );

    END TRY
    BEGIN CATCH
        -- Rollback transaction และ log error เมื่อเกิด exception
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_vch_error_code    = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();

        EXEC [inv].[usp_process_log]
             @in_vch_log_type        = 'STORED_PROCEDURE',
             @in_vch_device          = @in_vch_device,
             @in_vch_process         = 'usp_count_reconcile',
             @in_dt_process_datetime = @v_dt_process_start,
             @out_vch_error_code     = @out_vch_error_code,
             @out_vch_error_message  = @out_vch_error_message,
             @in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
