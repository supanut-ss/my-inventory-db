USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inbound_receipt]
-- ============================================================
ALTER PROCEDURE [inv].[usp_inbound_receipt]
    @in_int_inbound_master_id     BIGINT        = NULL,
    @in_int_inbound_detail_id     BIGINT        = NULL,
    @in_int_item_master_id        INT,
    @in_vch_uom                   NVARCHAR(10),
    @in_dec_qty                   DECIMAL(18, 4),
    @in_vch_lot_number            NVARCHAR(50)  = NULL,
    @in_dt_expiry_date           DATE          = NULL,
    @in_vch_serial_number         NVARCHAR(50)  = NULL,
    @in_int_receipt_location_id   INT,
    @in_vch_inv_status            NVARCHAR(50)  = 'Available',
    @in_vch_order_status          VARCHAR(20)   = 'OPEN',
    @in_vch_lang                  VARCHAR(20),
    @in_vch_user_id               NVARCHAR(50),
    @in_vch_device                NVARCHAR(50),
    @out_vch_inbound_order_number NVARCHAR(50)  OUTPUT,
    @out_vch_error_code           VARCHAR(50)   OUTPUT,
    @out_vch_error_message        NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @v_vch_error_code             VARCHAR(50),
        @v_vch_error_message          NVARCHAR(255),
        @v_vch_base_uom               NVARCHAR(10),
        @v_dec_base_qty               DECIMAL(18, 4),
        @v_dec_conv_factor            DECIMAL(18, 6),
        @v_vch_order_status           VARCHAR(20),
        @v_dec_rem_plan_qty           DECIMAL(18, 4),
        @v_bit_is_item_exist          BIT,
        @v_vch_item_number            NVARCHAR(50),
        @v_int_base_uom_id            INT,
        @v_vch_lot_control            VARCHAR(10),
        @v_vch_expiry_control         VARCHAR(10),
        @v_vch_sn_control             VARCHAR(10),
        @v_vch_plan_lot               NVARCHAR(50),
        @v_dt_plan_expiry            DATE,
        @v_vch_plan_serial            NVARCHAR(50),
        @v_int_serial_exists          INT,
        @v_vch_inbound_order_number   NVARCHAR(50),
        @v_int_warehouse_id           INT,
        @v_vch_warehouse              NVARCHAR(50),
        @v_int_owner_id               INT,
        @v_vch_owner_code             NVARCHAR(50),
        @v_vch_order_type             NVARCHAR(50),
        @v_vch_receipt_location       NVARCHAR(50),
        @v_vch_inv_status             NVARCHAR(50),
        @v_int_input_uom_id           INT,
        @v_int_inventory_id           BIGINT,
        @v_dt_process_start           DATETIME = GETDATE(),
        @v_int_receipt_header_id      BIGINT,
        @v_vch_receipt_number         NVARCHAR(50),
        @v_vch_item_description       NVARCHAR(255);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Auto-select warehouse: TOP 1 active ORDER BY create_date
        SELECT TOP 1
            @v_int_warehouse_id = warehouse_id,
            @v_vch_warehouse    = warehouse
        FROM [inv].[t_inv_warehouse]
        WHERE is_active = 1
        ORDER BY warehouse_id ASC;

        IF @v_int_warehouse_id IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_WAREHOUSE_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- Auto-select owner: TOP 1 active ORDER BY create_date
        SELECT TOP 1
            @v_int_owner_id   = owner_id,
            @v_vch_owner_code = owner_code
        FROM [inv].[t_inv_owner]
        WHERE is_active = 1
        ORDER BY owner_id ASC;

        IF @v_int_owner_id IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_OWNER_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- Auto-select order_type จาก combobox group 'inbound_order_type'
        SELECT TOP 1 @v_vch_order_type = value_member
        FROM [sec].[t_com_combobox_item]
        WHERE group_name = 'inbound_order_type'
          AND is_active  = 1
        ORDER BY display_sequence ASC;

        IF @v_vch_order_type IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_ORDER_TYPE_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- Resolve item_number และ item controls จาก item_master_id
        SELECT @v_vch_item_number       = item_number,
               @v_vch_item_description  = description,
               @v_vch_lot_control       = lot_control,
               @v_vch_expiry_control    = expiry_date_control,
               @v_vch_sn_control        = sn_control
        FROM [inv].[t_inv_item]
        WHERE item_master_id = @in_int_item_master_id;

        IF @v_vch_item_number IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_ITEM_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- สร้าง inbound master + detail ใหม่ถ้าไม่ได้ส่ง master_id มา
        IF @in_int_inbound_master_id IS NULL
        BEGIN
            EXEC [inv].[usp_generate_inbound_number]
                @out_vch_order_number = @v_vch_inbound_order_number OUTPUT;

            -- ใช้ NEXT VALUE FOR แทน SCOPE_IDENTITY() เพื่อความปลอดภัยใน multi-session
            SET @in_int_inbound_master_id = NEXT VALUE FOR [inv].[SEQInboundID];

            INSERT INTO [inv].[t_inv_inbound_master] (
                inbound_master_id,
                inbound_order_number,
                warehouse_id,
                warehouse,
                owner_id,
                owner_code,
                order_type,
                order_status,
                order_date,
                create_by,
                create_date
            )
            VALUES (
                @in_int_inbound_master_id,
                @v_vch_inbound_order_number,
                @v_int_warehouse_id,
                @v_vch_warehouse,
                @v_int_owner_id,
                @v_vch_owner_code,
                @v_vch_order_type,
                @in_vch_order_status,
                GETDATE(),
                @in_vch_user_id,
                GETDATE()
            );

            SET @in_int_inbound_detail_id = NEXT VALUE FOR [inv].[SEQInboundID];

            -- Insert detail โดยดึง primary UOM จาก t_inv_item_uom
            INSERT INTO [inv].[t_inv_inbound_detail] (
                inbound_detail_id,
                inbound_master_id,
                inbound_order_number,
                line_number,
                item_master_id,
                item_number,
                item_description,
                item_uom_id,
                uom,
                quantity_order,
                quantity_received,
                inv_status,
                lot_number,
                expiry_date,
                serial_number,
                create_by,
                create_date
            )
            SELECT
                @in_int_inbound_detail_id,
                @in_int_inbound_master_id,
                @v_vch_inbound_order_number,
                '1',
                @in_int_item_master_id,
                @v_vch_item_number,
                @v_vch_item_description,
                item_uom_id,
                uom,
                @in_dec_qty,
                0,
                @in_vch_inv_status,
                @in_vch_lot_number,
                @in_dt_expiry_date,
                @in_vch_serial_number,
                @in_vch_user_id,
                GETDATE()
            FROM [inv].[t_inv_item_uom]
            WHERE item_master_id = @in_int_item_master_id
              AND primary_uom    = 1;
        END

        -- Auto-resolve inbound_detail_id ถ้าไม่ได้ส่งมา (หา line ที่ยังรับไม่ครบ)
        IF @in_int_inbound_detail_id IS NULL
        BEGIN
            SELECT TOP 1
                @in_int_inbound_detail_id = id.inbound_detail_id
            FROM [inv].[t_inv_inbound_detail] id
            INNER JOIN [inv].[t_inv_inbound_master] im
                ON id.inbound_master_id = im.inbound_master_id
            WHERE id.inbound_master_id = @in_int_inbound_master_id
              AND id.item_master_id    = @in_int_item_master_id
              AND im.order_status     <> 'CLOSE'
              AND (id.quantity_order - ISNULL(id.quantity_received, 0)) > 0
            ORDER BY id.inbound_detail_id ASC;

            IF @in_int_inbound_detail_id IS NULL
            BEGIN
                SET @out_vch_error_code    = 'ERR_INBOUND_DETAIL_NOT_FOUND';
                SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
                RAISERROR(@out_vch_error_message, 16, 1);
            END
        END

        -- Gather order and UOM data
        SELECT
            @v_vch_order_status         = im.order_status,
            @v_bit_is_item_exist        = CASE WHEN id.inbound_detail_id IS NOT NULL THEN 1 ELSE 0 END,
            @v_dec_rem_plan_qty         = (id.quantity_order - ISNULL(id.quantity_received, 0)),
            @v_vch_plan_lot             = id.lot_number,
            @v_dt_plan_expiry          = id.expiry_date,
            @v_vch_plan_serial          = id.serial_number,
            @v_vch_inbound_order_number = im.inbound_order_number,
            @v_int_warehouse_id         = im.warehouse_id,
            @v_vch_warehouse            = im.warehouse,
            @v_int_owner_id             = im.owner_id,
            @v_vch_owner_code           = im.owner_code,
            @v_vch_inv_status           = id.inv_status,
            @v_int_input_uom_id         = uom_input.item_uom_id,
            @v_dec_conv_factor          = ISNULL(uom_input.conversion_factor, 1)
        FROM [inv].[t_inv_inbound_master] im
        LEFT JOIN [inv].[t_inv_inbound_detail] id
            ON  im.inbound_master_id = id.inbound_master_id
            AND id.inbound_detail_id = @in_int_inbound_detail_id
            AND id.item_master_id    = @in_int_item_master_id
        LEFT JOIN [inv].[t_inv_item_uom] uom_input
            ON  uom_input.item_master_id = @in_int_item_master_id
            AND uom_input.uom            = @in_vch_uom
        WHERE im.inbound_master_id = @in_int_inbound_master_id;

        -- ดึง Base UOM ของ item
        SELECT TOP 1
            @v_vch_base_uom    = uom,
            @v_int_base_uom_id = item_uom_id
        FROM [inv].[t_inv_item_uom]
        WHERE item_master_id = @in_int_item_master_id
          AND primary_uom    = 1;

        -- ดึงชื่อ location ที่รับของ
        SELECT @v_vch_receipt_location = location
        FROM [inv].[t_inv_location]
        WHERE location_id = @in_int_receipt_location_id;

        -- คำนวณ qty เป็น base UOM
        SET @v_dec_base_qty   = @in_dec_qty * @v_dec_conv_factor;
        -- fallback inv_status: ใช้ค่าจาก detail ก่อน ถ้าไม่มีให้ใช้ parameter
        SET @v_vch_inv_status = ISNULL(@v_vch_inv_status, @in_vch_inv_status);

        -- Validation: ตรวจสอบเงื่อนไขทั้งหมดก่อนดำเนินการ
        SELECT @v_vch_error_code = CASE
            WHEN @v_vch_order_status = 'CLOSE'                                                   THEN 'ERR_ORDER_CLOSED'
            WHEN @v_bit_is_item_exist = 0                                                        THEN 'ERR_ITEM_NOT_IN_ORDER'
            WHEN @v_int_input_uom_id IS NULL                                                     THEN 'ERR_UOM_NOT_FOUND'
            WHEN @v_vch_lot_control = 'FULL' AND ISNULL(@in_vch_lot_number, '') = ''            THEN 'ERR_LOT_REQUIRED'
            WHEN @v_vch_lot_control = 'NONE' AND ISNULL(@in_vch_lot_number, '') <> ''           THEN 'ERR_LOT_MUST_BE_EMPTY'
            WHEN @v_vch_expiry_control = 'FULL' AND @in_dt_expiry_date IS NULL                  THEN 'ERR_EXPIRY_REQUIRED'
            WHEN @v_vch_expiry_control = 'NONE' AND @in_dt_expiry_date IS NOT NULL              THEN 'ERR_EXPIRY_MUST_BE_EMPTY'
            WHEN @v_vch_sn_control = 'FULL' AND ISNULL(@in_vch_serial_number, '') = ''          THEN 'ERR_SERIAL_REQUIRED'
            WHEN @v_vch_sn_control = 'NONE' AND ISNULL(@in_vch_serial_number, '') <> ''         THEN 'ERR_SERIAL_MUST_BE_EMPTY'
            WHEN @v_vch_plan_lot IS NOT NULL AND @v_vch_plan_lot <> @in_vch_lot_number          THEN 'ERR_LOT_MISMATCH'
            WHEN @v_dt_plan_expiry IS NOT NULL AND @v_dt_plan_expiry <> @in_dt_expiry_date    THEN 'ERR_EXPIRY_MISMATCH'
            WHEN @v_vch_plan_serial IS NOT NULL AND @v_vch_plan_serial <> @in_vch_serial_number  THEN 'ERR_SERIAL_MISMATCH'
            WHEN @v_dec_base_qty > @v_dec_rem_plan_qty                                           THEN 'ERR_QTY_EXCEEDS_PLAN'
            ELSE 'SUCCESS'
        END;

        -- ตรวจ serial ซ้ำเพิ่มเติม (เฉพาะ FULL SN control และยังไม่มี error)
        IF @v_vch_sn_control = 'FULL' AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial] invs
            INNER JOIN [inv].[t_inv_inventory] inv ON invs.inventory_id = inv.inventory_id
            WHERE inv.item_master_id = @in_int_item_master_id
              AND invs.serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists > 0 SET @v_vch_error_code = 'ERR_SERIAL_DUPLICATE';
        END

        IF @v_vch_error_code <> 'SUCCESS'
        BEGIN
            SET @out_vch_error_code    = @v_vch_error_code;
            SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- หา receipt header ที่ยังเปิดอยู่ ถ้าไม่มีให้สร้างใหม่
        SELECT TOP 1
            @v_int_receipt_header_id = receipt_header_id,
            @v_vch_receipt_number    = receipt_number
        FROM [inv].[t_inv_inbound_receipt_header]
        WHERE inbound_master_id = @in_int_inbound_master_id
          AND receipt_status   <> 'CLOSED'
        ORDER BY create_date DESC;

        IF @v_int_receipt_header_id IS NULL
        BEGIN
            EXEC [inv].[usp_generate_receipt_number]
                @in_bIntInboundMasterID = @in_int_inbound_master_id,
                @in_vchInboundNumber    = @v_vch_inbound_order_number,
                @out_vchReceiptNumber   = @v_vch_receipt_number OUTPUT;

            SET @v_int_receipt_header_id = NEXT VALUE FOR [inv].[SEQInboundID];

            INSERT INTO [inv].[t_inv_inbound_receipt_header] (
                receipt_header_id,
                receipt_number,
                inbound_master_id,
                inbound_order_number,
                receipt_status,
                create_by,
                create_date
            )
            VALUES (
                @v_int_receipt_header_id,
                @v_vch_receipt_number,
                @in_int_inbound_master_id,
                @v_vch_inbound_order_number,
                'OPEN',
                @in_vch_user_id,
                GETDATE()
            );
        END

        -- Insert receipt detail
        INSERT INTO [inv].[t_inv_inbound_receipt_detail] (
            receipt_header_id,
            receipt_number,
            inbound_master_id,
            inbound_order_number,
            inbound_detail_id,
            receipt_location_id,
            receipt_location,
            item_master_id,
            item_number,
            quantity_received,
            item_uom_id,
            uom,
            receipt_inv_status,
            lot_number,
            expiry_date,
            serial_number,
            receive_date,
            create_by,
            create_date
        )
        VALUES (
            @v_int_receipt_header_id,
            @v_vch_receipt_number,
            @in_int_inbound_master_id,
            @v_vch_inbound_order_number,
            @in_int_inbound_detail_id,
            @in_int_receipt_location_id,
            @v_vch_receipt_location,
            @in_int_item_master_id,
            @v_vch_item_number,
            @v_dec_base_qty,
            @v_int_base_uom_id,
            @v_vch_base_uom,
            @v_vch_inv_status,
            @in_vch_lot_number,
            @in_dt_expiry_date,
            @in_vch_serial_number,
            GETDATE(),
            @in_vch_user_id,
            GETDATE()
        );

        -- อัปเดตจำนวนที่รับแล้วใน inbound detail
        UPDATE [inv].[t_inv_inbound_detail]
        SET quantity_received = quantity_received + @v_dec_base_qty,
            update_by         = @in_vch_user_id,
            update_date       = GETDATE()
        WHERE inbound_detail_id = @in_int_inbound_detail_id;

        -- UPSERT inventory: เพิ่มจำนวนถ้ามีอยู่แล้ว / สร้างใหม่ถ้าไม่มี
        MERGE [inv].[t_inv_inventory] AS target
        USING (
            SELECT
                @v_int_warehouse_id         AS warehouse_id,
                @v_vch_warehouse            AS warehouse,
                @v_int_owner_id             AS owner_id,
                @v_vch_owner_code           AS owner_code,
                @in_int_receipt_location_id AS location_id,
                @v_vch_receipt_location     AS location,
                @in_int_item_master_id      AS item_master_id,
                @v_vch_item_number          AS item_number,
                @v_vch_inv_status           AS inv_status,
                @in_vch_lot_number          AS lot_number,
                @in_dt_expiry_date         AS expiry_date
        ) AS source
        ON  target.warehouse_id                          = source.warehouse_id
            AND target.owner_id                          = source.owner_id
            AND target.location_id                       = source.location_id
            AND target.item_master_id                    = source.item_master_id
            AND ISNULL(target.lot_number,  '')           = ISNULL(source.lot_number,  '')
            AND ISNULL(target.expiry_date, '')           = ISNULL(source.expiry_date, '')
            AND ISNULL(target.inv_status,  '')           = ISNULL(source.inv_status,  '')
        WHEN MATCHED THEN
            UPDATE SET
                quantity    = ISNULL(target.quantity, 0) + @v_dec_base_qty,
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
                quantity,
                inv_status,
                lot_number,
                expiry_date,
                receive_date,
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
                @v_dec_base_qty,
                source.inv_status,
                source.lot_number,
                source.expiry_date,
                CAST(GETDATE() AS DATE),
                @in_vch_user_id,
                GETDATE()
            );

        -- Insert serial number (เฉพาะ item ที่ควบคุม SN แบบ FULL)
        IF @v_vch_sn_control = 'FULL'
        BEGIN
            SELECT @v_int_inventory_id = inventory_id
            FROM [inv].[t_inv_inventory]
            WHERE warehouse_id  = @v_int_warehouse_id
              AND owner_id       = @v_int_owner_id
              AND location_id    = @in_int_receipt_location_id
              AND item_master_id = @in_int_item_master_id
              AND ISNULL(lot_number,  '')           = ISNULL(@in_vch_lot_number,  '')
              AND ISNULL(expiry_date, '')           = ISNULL(@in_dt_expiry_date, '');

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

        -- Transaction Log
        -- หมายเหตุ: location_id = after_location_id เพราะ Receipt คือการรับของเข้า
        -- ของเข้าสู่ระบบที่ location นี้โดยตรง จึงไม่มี "before location"
        INSERT INTO [inv].[t_inv_tran_log] (
            tran_type,
            sub_tran_type,
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
            create_by,
            create_date
        )
        VALUES (
            'IO_RECEIPT',
            'RECEIPT',
            @v_int_warehouse_id,
            @v_vch_warehouse,
            @v_int_owner_id,
            @v_vch_owner_code,
            @in_int_receipt_location_id,
            @v_vch_receipt_location,
            @in_int_receipt_location_id,
            @v_vch_receipt_location,
            @in_int_item_master_id,
            @v_vch_item_number,
            @v_dec_base_qty,
            @v_int_base_uom_id,
            @v_vch_base_uom,
            @v_vch_inv_status,
            @v_vch_inv_status,
            CAST(GETDATE() AS DATE),
            @in_vch_lot_number,
            @in_vch_lot_number,
            @in_dt_expiry_date,
            @in_dt_expiry_date,
            @in_vch_serial_number,
            @in_vch_user_id,
            GETDATE()
        );

        COMMIT TRANSACTION;

        SET @out_vch_inbound_order_number = @v_vch_inbound_order_number;
        SET @out_vch_error_code           = '0';
        -- ดึง success message จาก resource table (รองรับ multi-language)
        SET @out_vch_error_message        = [sec].usf_get_resouce_value('STORED_PROCEDURE','SAVE_SUCCESS',@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_vch_error_code    = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();

        EXEC [inv].[usp_process_log]
             @in_vch_log_type        = 'STORED_PROCEDURE'  -- แก้จาก 'STORE_PROCEDURE'
            ,@in_vch_device          = @in_vch_device
            ,@in_vch_process         = 'usp_inbound_receipt'
            ,@in_dt_process_datetime = @v_dt_process_start
            ,@out_vch_error_code     = @out_vch_error_code
            ,@out_vch_error_message  = @out_vch_error_message
            ,@in_vch_user_id         = @in_vch_user_id;
    END CATCH
END
GO
