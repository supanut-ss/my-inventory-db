USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_mobile_inbound_binding_location]
-- ============================================================
ALTER PROCEDURE [inv].[usp_mobile_inbound_binding_location]
    @in_vch_item_number     NVARCHAR(50),
    @in_vch_lang            VARCHAR(20),
    @out_int_location_id    INT           OUTPUT,
    @out_vch_location       NVARCHAR(50)  OUTPUT,
    @out_vch_error_code     VARCHAR(50)   OUTPUT,
    @out_vch_error_message  NVARCHAR(255) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @v_int_item_master_id INT,
        @v_vch_error_code     VARCHAR(50),
        @v_vch_error_message  NVARCHAR(255);

    -- Step 1: Resolve item_master_id จาก t_inv_item (item หลัก)
    SELECT @v_int_item_master_id = item_master_id
    FROM [inv].[t_inv_item]
    WHERE item_number = @in_vch_item_number
        AND is_active = 1;

    -- Step 2: Fallback ไปหาใน t_inv_item_cross_ref (barcode สำรอง / alternate code)
    IF @v_int_item_master_id IS NULL
    BEGIN
        SELECT @v_int_item_master_id = item_master_id
        FROM [inv].[t_inv_item_cross_ref]
        WHERE (    item_number           = @in_vch_item_number
               OR  alternate_item_number = @in_vch_item_number)
            AND is_active = 1;
    END

    -- Guard: item ต้อง resolve ได้ก่อนดำเนินการต่อ
    IF @v_int_item_master_id IS NULL
    BEGIN
        SET @out_vch_error_code    = 'ERR_ITEM_NOT_FOUND';
        SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
        RETURN;
    END

    -- Delegate: ให้ SP ย่อยค้นหา putaway location ที่เหมาะสม
    EXEC [inv].[usp_inv_suggest_putaway_location]
         @in_int_item_master_id = @v_int_item_master_id
        ,@out_int_location_id   = @out_int_location_id  OUTPUT
        ,@out_vch_location      = @out_vch_location     OUTPUT;

    -- Guard: แจ้งเตือนถ้าหา location ไม่ได้ (ไม่ raise error เพราะ caller ยังเลือก location เองได้)
    IF @out_int_location_id IS NULL
    BEGIN
        SET @out_vch_error_code    = 'WARN_NO_SUGGEST_LOCATION';
        SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE',@out_vch_error_code,@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
        -- ไม่ RETURN เพื่อให้ยังส่ง result sets กลับไปให้ client เลือก location เองได้
    END

    -- Result Set 1: ข้อมูล item (controls สำหรับ UI validation)
    SELECT
        itm.item_master_id,
        itm.item_number,
        itm.description,
        itm.lot_control         AS is_control_lot,
        itm.expiry_date_control AS is_control_expiry,
        itm.sn_control          AS is_control_serial
    FROM [inv].[t_inv_item] itm
    WHERE itm.item_master_id = @v_int_item_master_id;

    -- Result Set 2: รายการ location ที่ใช้รับของได้ทั้งหมด (ตาม rule LOC_TYPE_FOR_RECEIVE)
    SELECT
        loc.location_id,
        loc.location,
        loc.loc_type,
        loc.putaway_sequence
    FROM [inv].[t_inv_location] loc
    WHERE loc.is_active  = 1
        AND loc.loc_type IN (
            SELECT value
            FROM [inv].[t_inv_rule]
            WHERE rule_code = 'LOC_TYPE_FOR_RECEIVE'
                AND is_active = 1
        )
    ORDER BY
        loc.putaway_sequence ASC,
        loc.location         ASC;

    -- Result Set 3: รายการ UOM ที่ active ทั้งหมดของ item นี้ (primary UOM ขึ้นก่อน)
    SELECT
        iuom.item_uom_id,
        iuom.uom,
        iuom.primary_uom,
        iuom.conversion_factor,
        iuom.sequence
    FROM [inv].[t_inv_item_uom] iuom
    WHERE iuom.item_master_id = @v_int_item_master_id
        AND iuom.is_active    = 1
    ORDER BY
        iuom.primary_uom DESC,
        iuom.sequence    ASC;

    -- Set success code เฉพาะเมื่อยังไม่มี warning/error จาก suggest location
    IF @out_vch_error_code IS NULL
    BEGIN
        SET @out_vch_error_code    = '0';
        SET @out_vch_error_message = [sec].usf_get_resouce_value('STORED_PROCEDURE','SAVE_SUCCESS',@in_vch_lang,'@param1','@param2','@param3','@param4','@param5');
    END
END
GO
