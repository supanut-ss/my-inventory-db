USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [inv].[usp_inventory_adjustment]
    @in_int_inventory_id    BIGINT = NULL,
    @in_vch_adj_type        VARCHAR(10),
    @in_dec_qty             DECIMAL(18, 4),
    @in_vch_lot_number      NVARCHAR(50)  = NULL,
    @in_dat_expiry_date     DATE          = NULL,
    @in_vch_serial_number   NVARCHAR(50)  = NULL,
    @in_vch_reason          NVARCHAR(200) = NULL,
    @in_vch_lang            VARCHAR(20),             -- ✅ เพิ่ม
    @in_vch_device          NVARCHAR(50)  = NULL,
    @in_vch_user_id         NVARCHAR(50),
    @out_vch_error_code     VARCHAR(50)   OUTPUT,
    @out_vch_error_message  NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE 
        @v_vch_error_code           VARCHAR(50),
        @v_vch_error_message        NVARCHAR(255),
        @v_int_warehouse_id         INT,
        @v_vch_warehouse            NVARCHAR(50),
        @v_int_owner_id             INT,
        @v_vch_owner_code           NVARCHAR(50),
        @v_int_location_id          INT,
        @v_vch_location             NVARCHAR(50),
        @v_int_item_master_id       INT,
        @v_vch_item_number          NVARCHAR(50),
        @v_vch_item_description     NVARCHAR(200),
        @v_dec_current_qty          DECIMAL(18, 4),
        @v_vch_inv_status           NVARCHAR(50),
        @v_dat_receive_date         DATE,
        @v_vch_lot_control          VARCHAR(10),
        @v_vch_expiry_control       VARCHAR(10),
        @v_vch_sn_control           VARCHAR(10),
        @v_int_item_uom_id          INT,
        @v_vch_uom                  NVARCHAR(10),
        @v_int_serial_exists        INT,
        @v_dt_process_start         DATETIME = GETDATE();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- If inventory_id is NULL, try to find it from other parameters
        IF @in_int_inventory_id IS NULL
        BEGIN
            SELECT TOP 1 @in_int_inventory_id = inventory_id
            FROM [inv].[t_inv_inventory]
            WHERE item_number   = @v_vch_item_number
              AND location_id   = @v_int_location_id
              AND ISNULL(lot_number, '') = ISNULL(@in_vch_lot_number, '')
              AND ISNULL(expiry_date, '1900-01-01') = ISNULL(@in_dat_expiry_date, '1900-01-01')
              AND ISNULL(inv_status, '') = ISNULL(@v_vch_inv_status, '')
            ORDER BY inventory_id ASC;
        END

        -- Gather inventory data
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
            @v_dat_receive_date     = inv.receive_date
        FROM [inv].[t_inv_inventory] inv
        WHERE inv.inventory_id = @in_int_inventory_id;

        -- Get item control settings
        SELECT
            @v_vch_lot_control    = itm.lot_control,
            @v_vch_expiry_control = itm.expiry_date_control,
            @v_vch_sn_control     = itm.sn_control
        FROM [inv].[t_inv_item] itm
        WHERE itm.item_master_id = @v_int_item_master_id;

        -- Get base UOM
        SELECT TOP 1
            @v_int_item_uom_id  = iuom.item_uom_id,
            @v_vch_uom          = iuom.uom
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_master_id = @v_int_item_master_id
            AND iuom.primary_uom  = 1;

        -- Validation — ✅ เปลี่ยน error code เป็น descriptive names
        SELECT @v_vch_error_code = CASE
            WHEN @v_int_item_master_id IS NULL
                THEN 'ERR_INVENTORY_NOT_FOUND'
            WHEN @in_vch_adj_type NOT IN ('ADJUST_IN', 'ADJUST_OUT')
                THEN 'ERR_INVALID_ADJ_TYPE'
            WHEN @in_dec_qty <= 0
                THEN 'ERR_INVALID_QTY'
            WHEN @in_vch_adj_type = 'ADJUST_OUT' AND @in_dec_qty > @v_dec_current_qty
                THEN 'ERR_QTY_EXCEEDS_AVAILABLE'
            WHEN @v_vch_lot_control = 'FULL' AND ISNULL(@in_vch_lot_number, '') = ''
                THEN 'ERR_LOT_REQUIRED'
            WHEN @v_vch_lot_control = 'NONE' AND ISNULL(@in_vch_lot_number, '') <> ''
                THEN 'ERR_LOT_MUST_BE_EMPTY'
            WHEN @v_vch_expiry_control = 'FULL' AND @in_dat_expiry_date IS NULL
                THEN 'ERR_EXPIRY_REQUIRED'
            WHEN @v_vch_expiry_control = 'NONE' AND @in_dat_expiry_date IS NOT NULL
                THEN 'ERR_EXPIRY_MUST_BE_EMPTY'
            WHEN @v_vch_sn_control = 'FULL' AND ISNULL(@in_vch_serial_number, '') = ''
                THEN 'ERR_SERIAL_REQUIRED'
            WHEN @v_vch_sn_control = 'NONE' AND ISNULL(@in_vch_serial_number, '') <> ''
                THEN 'ERR_SERIAL_MUST_BE_EMPTY'
            ELSE 'SUCCESS'
        END;

        -- Check serial for ADJUST_IN
        IF @v_vch_sn_control = 'FULL'
            AND @in_vch_adj_type = 'ADJUST_IN'
            AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            INNER JOIN [inv].[t_inv_inventory] inv
                ON invs.inventory_id = inv.inventory_id
            WHERE inv.item_master_id   = @v_int_item_master_id
                AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists > 0
                SET @v_vch_error_code = 'ERR_SERIAL_DUPLICATE';
        END

        -- Check serial for ADJUST_OUT
        IF @v_vch_sn_control = 'FULL'
            AND @in_vch_adj_type = 'ADJUST_OUT'
            AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            WHERE invs.inventory_id   = @in_int_inventory_id
                AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists = 0
                SET @v_vch_error_code = 'ERR_SERIAL_NOT_FOUND';
        END

        -- Return error if validation failed
        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            -- ✅ ใช้ usf_get_resouce_value แทน hardcoded message
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- Update inventory quantity
        UPDATE [inv].[t_inv_inventory]
        SET quantity    = CASE @in_vch_adj_type
                            WHEN 'ADJUST_IN'  THEN quantity + @in_dec_qty
                            WHEN 'ADJUST_OUT' THEN quantity - @in_dec_qty
                          END,
            update_by   = @in_vch_user_id,
            update_date = GETDATE()
        WHERE inventory_id = @in_int_inventory_id;

        -- Delete inventory if quantity reaches zero
        IF @in_vch_adj_type = 'ADJUST_OUT'
            AND (@v_dec_current_qty - @in_dec_qty) = 0
        BEGIN
            DELETE FROM [inv].[t_inv_inventory_serial]
            WHERE inventory_id = @in_int_inventory_id;

            DELETE FROM [inv].[t_inv_inventory]
            WHERE inventory_id = @in_int_inventory_id;
        END

        -- Handle serial numbers
        IF @v_vch_sn_control = 'FULL'
        BEGIN
            IF @in_vch_adj_type = 'ADJUST_IN'
            BEGIN
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
            ELSE IF @in_vch_adj_type = 'ADJUST_OUT'
                AND (@v_dec_current_qty - @in_dec_qty) > 0
            BEGIN
                DELETE FROM [inv].[t_inv_inventory_serial]
                WHERE inventory_id   = @in_int_inventory_id
                    AND serial_number = @in_vch_serial_number;
            END
        END

        -- Transaction log
        INSERT INTO [inv].[t_inv_tran_log] (
            tran_type,
            sub_tran_type,
            description,
            warehouse_id,
            warehouse,
            owner_id,
            owner_code,
            location_id,
            location,
            after_location_id,
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
            'ADJUSTMENT',
            @in_vch_adj_type,
            @in_vch_reason,
            @v_int_warehouse_id,
            @v_vch_warehouse,
            @v_int_owner_id,
            @v_vch_owner_code,
            @v_int_location_id,
            @v_vch_location,
            @v_int_location_id,
            @v_vch_location,
            @v_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @in_dec_qty,
            @v_int_item_uom_id,
            @v_vch_uom,
            @v_vch_inv_status,
            @v_vch_inv_status,
            @v_dat_receive_date,
            @in_vch_lot_number,
            @in_vch_lot_number,
            @in_dat_expiry_date,
            @in_dat_expiry_date,
            @in_vch_serial_number,
            @in_vch_device,
            @in_vch_user_id,
            GETDATE()
        );

        COMMIT TRANSACTION;
        SET @out_vch_error_code    = '0';
        -- ✅ success message จาก resource
        SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE','SAVE_SUCCESS',@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_vch_error_code    = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();

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