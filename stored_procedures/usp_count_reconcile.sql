-- Created by GitHub Copilot in SSMS - review carefully before executing
/*
    Summary:
    This stored procedure [inv].[usp_count_reconcile] is designed to reconcile inventory count details
    and update or insert records into both [t_inv_count_detail] and [t_inv_count_reconcile] tables.
    It performs validation, handles error messaging via resource lookup, and logs process results.
    The procedure supports multi-language error messages and ensures transactional integrity.
*/

CREATE OR ALTER PROCEDURE [inv].[usp_count_reconcile]
    @in_int_count_master_id    BIGINT,
    @in_int_location_id        INT,
    @in_int_item_master_id     INT,
    @in_int_item_uom_id        INT,
    @in_dec_quantity_count     DECIMAL(18, 4),
    @in_vch_inv_status         NVARCHAR(50)  = NULL,
    @in_vch_lot_number         NVARCHAR(50)  = NULL,
    @in_dat_expiry_date        DATE          = NULL,
    @in_vch_serial_number      NVARCHAR(50)  = NULL,
    @in_vch_lang               VARCHAR(20),
    @in_vch_user_id            NVARCHAR(50),
    @in_vch_device             NVARCHAR(50)  = NULL,
    @out_vch_error_code        VARCHAR(50)   OUTPUT,
    @out_vch_error_message     NVARCHAR(255) OUTPUT
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
        @v_vch_uom                  NVARCHAR(10),
        @v_int_count_detail_id      BIGINT,
        @v_int_count_reconcile_id   BIGINT,
        @v_dec_quantity_stock       DECIMAL(18, 4),
        @v_dat_receive_date         DATE,
        @v_vch_expiry_date_str      NVARCHAR(50),
        @v_dt_process_start         DATETIME = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Retrieve count master information
        SELECT
            @v_vch_close_by     = close_by,
            @v_int_warehouse_id = warehouse_id,
            @v_vch_warehouse    = warehouse,
            @v_int_owner_id     = owner_id,
            @v_vch_owner_code   = owner_code
        FROM [inv].[t_inv_count_master]
        WHERE count_master_id = @in_int_count_master_id;

        -- Retrieve location name
        SELECT
            @v_vch_location = location
        FROM [inv].[t_inv_location]
        WHERE location_id = @in_int_location_id;

        -- Retrieve item information
        SELECT
            @v_vch_item_number      = item_number,
            @v_vch_item_description = description
        FROM [inv].[t_inv_item]
        WHERE item_master_id = @in_int_item_master_id;

        -- Retrieve UOM information
        SELECT
            @v_vch_uom = uom
        FROM [inv].[t_inv_item_uom]
        WHERE item_uom_id = @in_int_item_uom_id;

        -- แปลง expiry date เป็น string format ISO (yyyy-mm-dd) สำหรับเก็บใน count_detail
        -- ใช้ format 23 เพื่อให้ตรงกับ column type ใน t_inv_count_detail ที่เก็บเป็น NVARCHAR
        SET @v_vch_expiry_date_str = CONVERT(NVARCHAR(50), @in_dat_expiry_date, 23);

        -- Validation: ตรวจสอบเงื่อนไขทั้งหมดก่อนดำเนินการ
        SELECT @v_vch_error_code = CASE
            WHEN @v_int_warehouse_id IS NULL THEN 'ERR_COUNT_MASTER_NOT_FOUND'
            WHEN @v_vch_close_by IS NOT NULL THEN 'ERR_COUNT_ALREADY_CLOSED'
            WHEN @v_vch_location IS NULL     THEN 'ERR_LOCATION_NOT_FOUND'
            WHEN @v_vch_item_number IS NULL  THEN 'ERR_ITEM_NOT_FOUND'
            WHEN @v_vch_uom IS NULL          THEN 'ERR_UOM_NOT_FOUND'
            WHEN @in_dec_quantity_count < 0  THEN 'ERR_INVALID_QTY'
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

        -- ตรวจหา count detail line ที่มีอยู่แล้ว
        -- หมายเหตุ: expiry_date ใน t_inv_count_detail เก็บเป็น NVARCHAR จึงเปรียบเทียบด้วย string
        SELECT
            @v_int_count_detail_id = count_detail_id,
            @v_dec_quantity_stock  = quantity_stock,
            @v_dat_receive_date    = receive_date
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
            -- หมายเหตุ: ใน t_inv_inventory ใช้ DATE type จึงเปรียบเทียบด้วย DATE โดยตรง
            SELECT @v_dec_quantity_stock = ISNULL(quantity, 0)
            FROM [inv].[t_inv_inventory]
            WHERE warehouse_id     = @v_int_warehouse_id
                AND owner_id       = @v_int_owner_id
                AND location_id    = @in_int_location_id
                AND item_master_id = @in_int_item_master_id
                AND ISNULL(inv_status,  '') = ISNULL(@in_vch_inv_status, '')
                AND ISNULL(lot_number,  '') = ISNULL(@in_vch_lot_number, '')
                AND ISNULL(expiry_date, '1900-01-01') = ISNULL(@in_dat_expiry_date, '1900-01-01');

            SET @v_dat_receive_date = CAST(GETDATE() AS DATE);

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
                @in_int_item_uom_id,
                @v_vch_uom,
                @in_vch_inv_status,
                @in_vch_lot_number,
                @v_vch_expiry_date_str,
                @in_vch_serial_number,
                @v_dat_receive_date,
                @in_vch_user_id,
                GETDATE(),
                @in_vch_user_id,
                GETDATE()
            );
        END

        -- Upsert count_reconcile: ตารางสรุปผลการ reconcile (ใช้ควบคู่กับ count_detail)
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
                @in_int_item_uom_id,
                @v_vch_uom,
                @in_vch_inv_status,
                @in_vch_lot_number,
                @v_vch_expiry_date_str,
                @in_vch_serial_number,
                @v_dat_receive_date,
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
             @in_vch_log_type        = 'STORED_PROCEDURE',   -- แก้จาก 'STORE_PROCEDURE'
             @in_vch_device          = @in_vch_device,
             @in_vch_process         = 'usp_count_reconcile', -- แก้ให้ตรงกับชื่อ SP จริง
             @in_dt_process_datetime = @v_dt_process_start,
             @out_vch_error_code     = @out_vch_error_code,
             @out_vch_error_message  = @out_vch_error_message,
             @in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
