USE [MyInventory]
GO

/****** Object:  StoredProcedure [inv].[usp_inv_suggest_putaway_location]    Script Date: 26/05/2026 10:29:54 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [inv].[usp_inv_suggest_putaway_location]
    @in_int_item_master_id  INT,
    @out_int_location_id    INT           OUTPUT,
    @out_vch_location       NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @v_int_category_id INT;

    -- Resolve category_id for the given item
    SELECT @v_int_category_id = category_id
    FROM [inv].[t_inv_item]
    WHERE item_master_id = @in_int_item_master_id
        AND is_active = 1;

    -- Select TOP 1 location via item → category → zone → location
    -- ถ้าไม่เจอ category → zc JOIN ไม่ match → return NULL
    SELECT TOP 1
        @out_int_location_id = loc.location_id,
        @out_vch_location    = loc.location
    FROM [inv].[t_inv_location] loc
    LEFT JOIN [inv].[t_inv_zone_location] zl  ON zl.location_id  = loc.location_id
    LEFT JOIN [inv].[t_inv_zone]          z   ON z.zone_id        = zl.zone_id
    LEFT JOIN [inv].[t_inv_zone_category] zc  ON zc.zone_id       = z.zone_id
                                              AND zc.category_id   = @v_int_category_id
    WHERE loc.is_active = 1
        AND loc.loc_type = 'PICK'
        AND NOT EXISTS (
            SELECT 1 FROM [inv].[t_inv_inventory] inv
            WHERE inv.location_id = loc.location_id
        )
    ORDER BY loc.putaway_sequence ASC, loc.location ASC;
END
GO


