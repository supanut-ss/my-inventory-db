USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inbound_close_receipt]
-- ============================================================
CREATE OR ALTER PROCEDURE [inv].[usp_inbound_close_receipt]
    @in_int_inbound_master_id BIGINT,
    @in_vch_lang              VARCHAR(20),
    @in_vch_user_id           NVARCHAR(50),
    @in_vch_device            NVARCHAR(50),
    @out_vch_error_code       VARCHAR(50)   OUTPUT,
    @out_vch_error_message    NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @v_dt_process_start         DATETIME      = GETDATE(),
        @v_vch_inbound_order_number NVARCHAR(50),
        @v_vch_old_status           VARCHAR(20),
        @v_int_close_detail         INT = 0,
        @v_int_close_receipt        INT = 0;

    BEGIN TRY

        BEGIN TRANSACTION;
        -- ============================================================
        -- Validate Inbound Master
        -- ============================================================
        SELECT
            @v_vch_inbound_order_number = inbound_order_number,
            @v_vch_old_status           = order_status
        FROM [inv].[t_inv_inbound_master]
        WHERE inbound_master_id = @in_int_inbound_master_id;

        IF @v_vch_inbound_order_number IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_INBOUND_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                                                'STORED_PROCEDURE',
                                                @out_vch_error_code,
                                                @in_vch_lang,
                                                '@param1','@param2','@param3','@param4','@param5'
                                            );

            RAISERROR(@out_vch_error_message, 16, 1);
        END

        IF @v_vch_old_status = 'CLOSE'
        BEGIN
            SET @out_vch_error_code    = 'ERR_INBOUND_ALREADY_CLOSE';
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                                                'STORED_PROCEDURE',
                                                @out_vch_error_code,
                                                @in_vch_lang,
                                                '@param1','@param2','@param3','@param4','@param5'
                                            );

            RAISERROR(@out_vch_error_message, 16, 1);
        END
        -- ============================================================
        -- Close Inbound Detail
        -- ============================================================
        UPDATE d
        SET
            d.inv_status = 'CLOSE',
            d.update_by    = @in_vch_user_id,
            d.update_date  = GETDATE()
        FROM [inv].[t_inv_inbound_detail] d
        WHERE d.inbound_master_id = @in_int_inbound_master_id
          AND ISNULL(d.inv_status,'OPEN') <> 'CLOSE';

        SET @v_int_close_detail = @@ROWCOUNT;
        -- ============================================================
        -- Close Receipt Detail
        -- ============================================================
        UPDATE rd
        SET
            rd.receipt_inv_status = 'CLOSE',
            rd.update_by      = @in_vch_user_id,
            rd.update_date    = GETDATE()
        FROM [inv].[t_inv_inbound_receipt_detail] rd
        INNER JOIN [inv].[t_inv_inbound_receipt_header] rh
            ON rh.receipt_header_id = rd.receipt_header_id
        WHERE rh.inbound_master_id = @in_int_inbound_master_id
          AND ISNULL(rd.receipt_inv_status,'receipt_status') <> 'CLOSE';
        -- ============================================================
        -- Close Receipt Header
        -- ============================================================
        UPDATE rh
        SET
            rh.receipt_status = 'CLOSE',
            rh.close_by       = @in_vch_user_id,
            rh.close_date     = GETDATE()
        FROM [inv].[t_inv_inbound_receipt_header] rh
        WHERE rh.inbound_master_id = @in_int_inbound_master_id
          AND ISNULL(rh.receipt_status,'OPEN') <> 'CLOSE';

        SET @v_int_close_receipt = @@ROWCOUNT;
        -- ============================================================
        -- Close Inbound Master
        -- ============================================================
        UPDATE [inv].[t_inv_inbound_master]
        SET
            order_status = 'CLOSE',
            close_by    = @in_vch_user_id,
            close_date  = GETDATE()
        WHERE inbound_master_id = @in_int_inbound_master_id;
        -- ============================================================
        -- Transaction Log
        -- ============================================================
        INSERT INTO [inv].[t_inv_tran_log]
        (
            tran_type,
            sub_tran_type,
            description,
            warehouse_id,
            owner_id,
            item_master_id,
            item_number,
            item_description,
            quantity,
            inv_status,
            after_inv_status,
            order_number,
            reference_number,
            order_type,
            device,
            create_by,
            create_date
        )
        SELECT
            'INBOUND',
            'CLOSE_RECEIPT',
            CONCAT(
                'Close inbound receipt : ',
                im.inbound_order_number
            ),
            im.warehouse_id,
            im.owner_id,
            d.item_master_id,
            d.item_number,
            d.item_description,
            d.quantity_received,
            d.inv_status,
            'CLOSE',
            im.inbound_order_number,
            rh.receipt_number,
            im.order_type,
            @in_vch_device,
            @in_vch_user_id,
            GETDATE()
        FROM [inv].[t_inv_inbound_master] im
        INNER JOIN [inv].[t_inv_inbound_detail] d
            ON im.inbound_master_id = d.inbound_master_id
        LEFT JOIN [inv].[t_inv_inbound_receipt_header] rh
            ON im.inbound_master_id = rh.inbound_master_id
        WHERE im.inbound_master_id = @in_int_inbound_master_id;
        -- ============================================================
        -- Process Log
        -- ============================================================
        EXEC [inv].[usp_process_log]
             @in_vch_log_type        = 'STORED_PROCEDURE'
            ,@in_vch_device          = @in_vch_device
            ,@in_vch_process         = 'usp_inbound_close_receipt'
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = '0'
            ,@out_vch_error_message  = 'Close inbound receipt success'
            ,@in_vch_user_id         = @in_vch_user_id;

        COMMIT TRANSACTION;

        SET @out_vch_error_code    = '0';
        SET @out_vch_error_message = 'Close inbound receipt success';

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @out_vch_error_code = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();

        EXEC [inv].[usp_process_log]
             @in_vch_log_type        = 'STORED_PROCEDURE'
            ,@in_vch_device          = @in_vch_device
            ,@in_vch_process         = 'usp_inbound_close_receipt'
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = @out_vch_error_code
            ,@out_vch_error_message  = @out_vch_error_message
            ,@in_vch_user_id         = @in_vch_user_id;

    END CATCH

END
GO
