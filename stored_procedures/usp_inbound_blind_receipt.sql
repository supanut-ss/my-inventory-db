USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inbound_blind_receipt]
-- ============================================================
ALTER PROCEDURE [inv].[usp_inbound_blind_receipt]
    -- --------------------------------------------------------
    -- Blind Receipt: รับสินค้าโดยไม่อ้างอิง inbound_detail_id
    -- ข้อมูลที่ส่งเข้ามาเป็น ID ทั้งหมด
    -- --------------------------------------------------------
    @in_int_inbound_master_id     BIGINT        = NULL,  -- NULL = สร้าง inbound master ใหม่
    @in_int_item_master_id        INT,
    @in_int_input_uom_id          INT,
    @in_dec_qty                   DECIMAL(18, 4),
    @in_vch_lot_number            NVARCHAR(50)  = NULL,
    @in_dat_expiry_date           DATE          = NULL,
    @in_vch_serial_number         NVARCHAR(50)  = NULL,
    @in_int_receipt_location_id   INT,
    @in_int_receipt_header_id     BIGINT        = NULL,  -- NULL = หา/สร้างใหม่
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

    -- --------------------------------------------------------
    -- Internal Variables (Consolidated Declaration)
    -- --------------------------------------------------------
    DECLARE
        @v_vch_error_code           VARCHAR(50),
        @v_vch_error_message        NVARCHAR(255),
        @v_vch_item_number          NVARCHAR(50),
        @v_vch_item_description     NVARCHAR(255),
        @v_vch_lot_control          VARCHAR(10),
        @v_vch_expiry_control       VARCHAR(10),
        @v_vch_sn_control           VARCHAR(10),
        @v_vch_input_uom            NVARCHAR(10),
        @v_dec_conv_factor          DECIMAL(18, 6),
        @v_bit_is_base_uom          BIT,
        @v_int_base_uom_id          INT,
        @v_vch_base_uom             NVARCHAR(10),
        @v_dec_base_qty             DECIMAL(18, 4),
        @v_vch_order_status         VARCHAR(20),
        @v_vch_inbound_order_number NVARCHAR(50),
        @v_int_warehouse_id         INT,
        @v_vch_warehouse            NVARCHAR(50),
        @v_int_owner_id             INT,
        @v_vch_owner_code           NVARCHAR(50),
        @v_vch_order_type           NVARCHAR(50),
        @v_vch_receipt_location     NVARCHAR(50),
        @v_vch_inv_status           NVARCHAR(50),
        @v_int_inventory_id         BIGINT,
        @v_int_serial_exists        INT,
        @v_dt_process_start         DATETIME = GETDATE(),
        @v_int_receipt_header_id    BIGINT,
        @v_vch_receipt_number       NVARCHAR(50),
        @v_int_inbound_detail_id    BIGINT;

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
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                'STORED_PROCEDURE',
                @out_vch_error_code,
                @in_vch_lang,
                '@param1','@param2','@param3','@param4','@param5'
            );
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
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                'STORED_PROCEDURE',
                @out_vch_error_code,
                @in_vch_lang,
                '@param1','@param2','@param3','@param4','@param5'
            );
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- Select order_type สำหรับ Blind Receipt (ไม่ดึงจาก combobox)
       
        SELECT @v_vch_order_type = VALUE FROM [inv].[t_inv_rule] 
        WHERE rule_code = 'ORDER_TYPE_FOR_BLIND_RECEIPT' 
        AND is_active = 1
        IF(ISNULL(@v_vch_order_type,'') ='')
        BEGIN
            SET @v_vch_order_type = 'Blind Receipt';
        END

        -- Default inv_status ถ้าไม่ส่งมา
        SET @v_vch_inv_status = ISNULL(@in_vch_inv_status, 'Available');

        -- สร้าง inbound master ใหม่ถ้าไม่ได้ส่งมา
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
        END

        -- 1.1 Get Order Info
        SELECT
            @v_vch_order_status         = im.order_status,
            @v_vch_inbound_order_number = im.inbound_order_number,
            @v_int_warehouse_id         = im.warehouse_id,
            @v_vch_warehouse            = im.warehouse,
            @v_int_owner_id             = im.owner_id,
            @v_vch_owner_code           = im.owner_code
        FROM [inv].[t_inv_inbound_master] im
        WHERE im.inbound_master_id = @in_int_inbound_master_id;

        -- Guard: ถ้า inbound_order_number ยังเป็น NULL (master ไม่พบ) → raise error ก่อน
        -- เพื่อป้องกัน NULL ไหลไปใช้ใน usp_generate_receipt_number และ INSERT receipt_detail
        IF @v_vch_inbound_order_number IS NULL
        BEGIN
            SET @out_vch_error_code    = 'ERR_INBOUND_ORDER_NOT_FOUND';
            SET @out_vch_error_message = [sec].usf_get_resouce_value(
                'STORED_PROCEDURE',
                @out_vch_error_code,
                @in_vch_lang,
                '@param1','@param2','@param3','@param4','@param5'
            );
            RAISERROR(@out_vch_error_message, 16, 1);
        END

        -- 1.2 Get Item Info + controls
        SELECT
            @v_vch_item_number      = itm.item_number,
            @v_vch_item_description = itm.description,
            @v_vch_lot_control      = itm.lot_control,
            @v_vch_expiry_control   = itm.expiry_date_control,
            @v_vch_sn_control       = itm.sn_control
        FROM [inv].[t_inv_item] itm
        WHERE itm.item_master_id = @in_int_item_master_id;

        -- 1.3 Get Input UOM Info
        SELECT
            @v_vch_input_uom   = iuom.uom,
            @v_dec_conv_factor = ISNULL(iuom.conversion_factor, 1),
            @v_bit_is_base_uom = iuom.primary_uom
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_uom_id = @in_int_input_uom_id;

        -- 1.4 Get Base UOM
        SELECT TOP 1
            @v_vch_base_uom    = iuom.uom,
            @v_int_base_uom_id = iuom.item_uom_id
        FROM [inv].[t_inv_item_uom] iuom
        WHERE iuom.item_master_id = @in_int_item_master_id
          AND iuom.primary_uom    = 1;

        -- 1.5 Get Receipt Location
        SELECT
            @v_vch_receipt_location = loc.location
        FROM [inv].[t_inv_location] loc
        WHERE loc.location_id = @in_int_receipt_location_id;

        -- 1.6 Calculate Base Qty (แปลงจาก input UOM → base UOM)
        IF @v_bit_is_base_uom = 1
            SET @v_dec_base_qty = @in_dec_qty;
        ELSE
            SET @v_dec_base_qty = @in_dec_qty * @v_dec_conv_factor;

        -- --------------------------------------------------------
        -- 2. Validation — ตรวจสอบก่อน INSERT ทุกครั้ง
        -- --------------------------------------------------------
        SELECT @v_vch_error_code = CASE
            WHEN @v_vch_order_status IS NULL                                             THEN 'ERR_INBOUND_ORDER_NOT_FOUND'
            WHEN @v_vch_order_status = 'CLOSE'                                           THEN 'ERR_ORDER_CLOSED'
            WHEN @v_vch_item_number IS NULL                                              THEN 'ERR_ITEM_NOT_FOUND'
            WHEN @v_vch_input_uom IS NULL                                                THEN 'ERR_UOM_NOT_FOUND'
            WHEN @v_vch_base_uom IS NULL                                                 THEN 'ERR_BASE_UOM_NOT_FOUND'
            WHEN @v_vch_receipt_location IS NULL                                         THEN 'ERR_LOCATION_NOT_FOUND'
            WHEN @v_vch_lot_control = 'FULL' AND ISNULL(@in_vch_lot_number, '') = ''    THEN 'ERR_LOT_REQUIRED'
            WHEN @v_vch_lot_control = 'NONE' AND ISNULL(@in_vch_lot_number, '') <> ''   THEN 'ERR_LOT_MUST_BE_EMPTY'
            WHEN @v_vch_expiry_control = 'FULL' AND @in_dat_expiry_date IS NULL          THEN 'ERR_EXPIRY_REQUIRED'
            WHEN @v_vch_expiry_control = 'NONE' AND @in_dat_expiry_date IS NOT NULL      THEN 'ERR_EXPIRY_MUST_BE_EMPTY'
            WHEN @v_vch_sn_control = 'FULL' AND ISNULL(@in_vch_serial_number, '') = ''  THEN 'ERR_SERIAL_REQUIRED'
            WHEN @v_vch_sn_control = 'NONE' AND ISNULL(@in_vch_serial_number, '') <> '' THEN 'ERR_SERIAL_MUST_BE_EMPTY'
            ELSE 'SUCCESS'
        END;

        -- ตรวจ serial ซ้ำเพิ่มเติม (เฉพาะเมื่อ FULL SN control และยังไม่มี error)
        IF @v_vch_sn_control = 'FULL' AND @v_vch_error_code = 'SUCCESS'
        BEGIN
            SELECT
                @v_int_serial_exists = COUNT(*)
            FROM [inv].[t_inv_inventory_serial]
            WHERE serial_number = @in_vch_serial_number;

            IF @v_int_serial_exists > 0
                SET @v_vch_error_code = 'ERR_SERIAL_DUPLICATE';
        END

        -- หาก Validation ไม่ผ่าน ให้ raise error ก่อน (ไม่ต้อง INSERT)
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

        -- --------------------------------------------------------
        -- 3. Data Operations (หลัง Validation ผ่านแล้วเท่านั้น)
        -- --------------------------------------------------------

        -- 3.1 Create Inbound Detail (blind receipt สร้างใหม่ทุกครั้ง)
        -- quantity_order = quantity_received เพราะ blind receipt ถือว่าของมาครบ
        SET @v_int_inbound_detail_id = NEXT VALUE FOR [inv].[SEQInboundID];

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
        VALUES (
            @v_int_inbound_detail_id,
            @in_int_inbound_master_id,
            @v_vch_inbound_order_number,
            '1',
            @in_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @in_int_input_uom_id,
            @v_vch_input_uom,
            @v_dec_base_qty,
            @v_dec_base_qty,
            -- quantity_received = quantity_order สำหรับ blind receipt
            @v_vch_inv_status,
            @in_vch_lot_number,
            @in_dat_expiry_date,
            @in_vch_serial_number,
            @in_vch_user_id,
            GETDATE()
        );

        -- 3.2 Ensure Receipt Header (ใช้ค่าที่รับมาก่อน ถ้าไม่มีให้หาหรือสร้างใหม่)
        SET @v_int_receipt_header_id = @in_int_receipt_header_id;

        IF @v_int_receipt_header_id IS NULL
        BEGIN
            -- หา receipt header ที่ยังเปิดอยู่ของ master นี้
            SELECT TOP 1
                @v_int_receipt_header_id = receipt_header_id,
                @v_vch_receipt_number    = receipt_number
            FROM [inv].[t_inv_inbound_receipt_header]
            WHERE inbound_master_id = @in_int_inbound_master_id
              AND receipt_status   <> 'CLOSED'
            ORDER BY create_date DESC;
        END
        ELSE
        BEGIN
            -- ดึง receipt_number จาก header ID ที่รับมา
            SELECT
                @v_vch_receipt_number = receipt_number
            FROM [inv].[t_inv_inbound_receipt_header]
            WHERE receipt_header_id = @v_int_receipt_header_id;

            -- Guard: ถ้า header id ส่งมาแต่หาไม่พบในตาราง → receipt_number จะเป็น NULL
            -- ต้อง raise error แทนที่จะปล่อยให้ INSERT receipt_detail fail ด้วย error ที่อ่านยาก
            IF @v_vch_receipt_number IS NULL
            BEGIN
                SET @out_vch_error_code    = 'ERR_RECEIPT_HEADER_NOT_FOUND';
                SET @out_vch_error_message = [sec].usf_get_resouce_value(
                    'STORED_PROCEDURE',
                    @out_vch_error_code,
                    @in_vch_lang,
                    '@param1','@param2','@param3','@param4','@param5'
                );
                RAISERROR(@out_vch_error_message, 16, 1);
            END
        END

        -- ถ้าหา header ไม่ได้ ให้สร้างใหม่
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

        -- 3.3 Insert Receipt Detail
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
            item_description,
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
            @v_int_inbound_detail_id,
            @in_int_receipt_location_id,
            @v_vch_receipt_location,
            @in_int_item_master_id,
            @v_vch_item_number,
            @v_vch_item_description,
            @v_dec_base_qty,
            @v_int_base_uom_id,
            @v_vch_base_uom,
            @v_vch_inv_status,
            @in_vch_lot_number,
            @in_dat_expiry_date,
            @in_vch_serial_number,
            GETDATE(),
            @in_vch_user_id,
            GETDATE()
        );

        -- 3.4 Merge Inventory (UPSERT: เพิ่มจำนวนถ้ามีอยู่แล้ว / สร้างใหม่ถ้าไม่มี)
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
                @in_dat_expiry_date         AS expiry_date
        ) AS source
        ON  target.warehouse_id                          = source.warehouse_id
            AND target.owner_id                          = source.owner_id
            AND target.location_id                       = source.location_id
            AND target.item_master_id                    = source.item_master_id
            AND ISNULL(target.lot_number,  '')           = ISNULL(source.lot_number,  '')
            AND ISNULL(target.expiry_date, '') = ISNULL(source.expiry_date, '')
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

        -- 3.5 Insert Serial Number (เฉพาะ item ที่ควบคุม SN แบบ FULL)
        IF @v_vch_sn_control = 'FULL'
        BEGIN
            SELECT
                @v_int_inventory_id = inv.inventory_id
            FROM [inv].[t_inv_inventory] inv
            WHERE inv.warehouse_id    = @v_int_warehouse_id
              AND inv.owner_id         = @v_int_owner_id
              AND inv.location_id      = @in_int_receipt_location_id
              AND inv.item_master_id   = @in_int_item_master_id
              AND ISNULL(inv.lot_number,  '')           = ISNULL(@in_vch_lot_number,  '')
              AND ISNULL(inv.expiry_date, '') = ISNULL(@in_dat_expiry_date, '');

            IF @v_int_inventory_id IS NULL
            BEGIN
                SET @out_vch_error_code    = 'ERR_INVENTORY_NOT_FOUND';
                SET @out_vch_error_message = [sec].usf_get_resouce_value(
                    'STORED_PROCEDURE',
                    @out_vch_error_code,
                    @in_vch_lang,
                    '@param1','@param2','@param3','@param4','@param5'
                );
                RAISERROR(@out_vch_error_message, 16, 1);
            END

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

        -- 3.6 Transaction Log
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
            'BLIND_RECEIPT',
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
            @in_dat_expiry_date,
            @in_dat_expiry_date,
            @in_vch_serial_number,
            @in_vch_user_id,
            GETDATE()
        );

        COMMIT TRANSACTION;

        SET @out_vch_inbound_order_number = @v_vch_inbound_order_number;
        SET @out_vch_error_code           = '0';
        SET @out_vch_error_message        = [sec].usf_get_resouce_value(
            'STORED_PROCEDURE',
            'SAVE_SUCCESS',
            @in_vch_lang,
            '@param1','@param2','@param3','@param4','@param5'
        );

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_vch_error_code    = ISNULL(@out_vch_error_code, 'ERR_999');
        SET @out_vch_error_message = ERROR_MESSAGE();
    END CATCH

    -- บันทึก error log เฉพาะเมื่อเกิด error เท่านั้น
    IF @out_vch_error_code <> '0'
    BEGIN
        BEGIN TRY
            EXEC [inv].[usp_process_log]
                 @in_vch_log_type        = 'STORED_PROCEDURE',  -- แก้จาก 'STORE_PROCEDURE'
                 @in_vch_device          = @in_vch_device,
                 @in_vch_process         = 'usp_inbound_blind_receipt',
                 @in_dt_process_datetime = @v_dt_process_start,
                 @out_vch_error_code     = @out_vch_error_code,
                 @out_vch_error_message  = @out_vch_error_message,
                 @in_vch_user_id         = @in_vch_user_id;
        END TRY
        BEGIN CATCH
        END CATCH
    END
END
GO
