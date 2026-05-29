USE [MyInventory]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================
-- Object  : [inv].[usp_inv_suggest_putaway_location]
-- ============================================================
CREATE OR ALTER PROCEDURE [inv].[usp_inv_suggest_putaway_location]
    @in_int_item_master_id  INT,
    @out_int_location_id    INT           OUTPUT,
    @out_vch_location       NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @v_int_category_id INT;

    -- Resolve category_id จาก item ที่ระบุ (เฉพาะ item ที่ active)
    SELECT @v_int_category_id = category_id
    FROM [inv].[t_inv_item]
    WHERE item_master_id = @in_int_item_master_id
        AND is_active = 1;

    -- แนะนำ location ที่เหมาะสมโดยเดินตาม path: item → category → zone → location
    -- เงื่อนไข:
    --   1. location ต้อง active และเป็น loc_type = 'STORAGE' (สำหรับ putaway)
    --   2. zone ต้อง map กับ category ของ item นี้ (INNER JOIN บังคับให้ match)
    --   3. location ต้องว่างอยู่ (ไม่มี inventory ใดอยู่เลย)
    --   4. เรียงตาม putaway_sequence ก่อน แล้วตามชื่อ location
    SELECT TOP 1
        @out_int_location_id = loc.location_id,
        @out_vch_location    = loc.location
    FROM [inv].[t_inv_location] loc
    INNER JOIN [inv].[t_inv_zone_location] zl ON zl.location_id = loc.location_id
    INNER JOIN [inv].[t_inv_zone]          z  ON z.zone_id      = zl.zone_id
    INNER JOIN [inv].[t_inv_zone_category] zc ON zc.zone_id     = z.zone_id
                                              AND zc.category_id = @v_int_category_id
    WHERE loc.is_active = 1
        AND loc.loc_type = 'STORAGE'  -- แก้จาก 'PICK': putaway ต้องการ STORAGE location
        AND NOT EXISTS (
            SELECT 1 FROM [inv].[t_inv_inventory] inv
            WHERE inv.location_id = loc.location_id
        )
    ORDER BY
        loc.putaway_sequence ASC,
        loc.location ASC;

    -- หมายเหตุ: ถ้าไม่มี location ว่างที่ตรงกับ category
    -- @out_int_location_id และ @out_vch_location จะเป็น NULL
    -- ให้ caller ตรวจสอบ NULL ก่อนนำไปใช้งาน
END
GO
