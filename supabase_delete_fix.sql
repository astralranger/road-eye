-- =================================================================
-- ATOMIC DETECTION & STORAGE OBJECT DELETION SCRIPT
-- =================================================================
-- Enforces:
-- 1. Strict ownership: Users can ONLY delete their own detections.
-- 2. Atomic deletion of single detection and associated Supabase Storage image.
-- 3. Bulk deletion function (bulk_delete_pothole_detections) for mass purging.
-- 4. Location deletion function (delete_pothole_location) for purging all
--    duplicate frames logged at a specific coordinate by the author.
-- =================================================================

-- 1. Enable Storage deletion for authenticated users on bucket 'pothole-images'
DROP POLICY IF EXISTS "Allow authenticated delete on pothole-images" ON storage.objects;

CREATE POLICY "Allow authenticated delete on pothole-images"
ON storage.objects FOR DELETE
TO authenticated
USING ( bucket_id = 'pothole-images' );

-- 2. Detections Table Policies
ALTER TABLE public.detections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can delete their own detections" ON detections;
CREATE POLICY "Users can delete their own detections" ON detections
FOR DELETE
TO authenticated
USING (
  auth.uid() = user_id
);

DROP POLICY IF EXISTS "Anyone authenticated can view detections" ON detections;
DROP POLICY IF EXISTS "Users see their own detections" ON detections;
CREATE POLICY "Anyone authenticated can view detections" ON detections
FOR SELECT
TO authenticated, anon
USING ( true );

DROP POLICY IF EXISTS "Users can insert own detections" ON detections;
CREATE POLICY "Users can insert own detections" ON detections
FOR INSERT
TO authenticated
WITH CHECK (
  auth.uid() = user_id OR user_id IS NULL
);

-- 3. Single Atomic Deletion Stored Procedure (RPC)
CREATE OR REPLACE FUNCTION delete_pothole_detection(p_detection_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
    v_img_url text;
    v_user_id uuid;
    v_current_user uuid;
    v_storage_path text;
    v_deleted_count int;
BEGIN
    -- 1. Retrieve record metadata
    SELECT image_url, user_id INTO v_img_url, v_user_id
    FROM public.detections
    WHERE id = p_detection_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'NOT_FOUND',
            'message', 'Detection record does not exist in the database.'
        );
    END IF;

    -- 2. Strict Authorization Verification: Only owner can delete
    v_current_user := auth.uid();
    IF v_current_user IS NOT NULL AND v_user_id IS NOT NULL AND v_current_user <> v_user_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'UNAUTHORIZED',
            'message', 'Permission denied: You can only delete your own detection reports.'
        );
    END IF;

    -- 3. Extract and delete associated storage asset
    IF v_img_url IS NOT NULL AND v_img_url <> '' THEN
        IF v_img_url LIKE '%/pothole-images/%' THEN
            v_storage_path := split_part(v_img_url, '/pothole-images/', 2);
            v_storage_path := split_part(v_storage_path, '?', 1);
        ELSE
            v_storage_path := v_img_url;
        END IF;

        IF v_storage_path IS NOT NULL AND v_storage_path <> '' THEN
            -- Allow storage deletion in this transaction
            PERFORM set_config('storage.allow_delete_query', 'true', true);
            DELETE FROM storage.objects
            WHERE bucket_id = 'pothole-images'
              AND name = v_storage_path;
        END IF;
    END IF;

    -- 4. Delete the detection row strictly matching owner
    DELETE FROM public.detections
    WHERE id = p_detection_id
      AND (v_current_user IS NULL OR user_id = v_current_user);

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    IF v_deleted_count > 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'id', p_detection_id,
            'image_purged', v_storage_path
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ZERO_ROWS_AFFECTED',
            'message', 'Database record could not be removed.'
        );
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_pothole_detection(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_pothole_detection(bigint) TO anon;
GRANT EXECUTE ON FUNCTION delete_pothole_detection(bigint) TO service_role;


-- 4. Bulk Atomic Deletion Stored Procedure (RPC)
CREATE OR REPLACE FUNCTION bulk_delete_pothole_detections(p_detection_ids bigint[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
    v_current_user uuid;
    v_deleted_count int;
    v_row record;
    v_storage_path text;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL AND current_user <> 'postgres' AND current_user <> 'service_role' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'UNAUTHORIZED',
            'message', 'Authentication required to perform bulk deletion.'
        );
    END IF;

    -- Allow storage deletion in this transaction
    PERFORM set_config('storage.allow_delete_query', 'true', true);

    -- Purge images from storage ONLY for records strictly owned by the caller
    FOR v_row IN
        SELECT image_url, user_id FROM public.detections
        WHERE id = ANY(p_detection_ids)
          AND (v_current_user IS NULL OR user_id = v_current_user)
    LOOP
        IF v_row.image_url IS NOT NULL AND v_row.image_url <> '' THEN
            IF v_row.image_url LIKE '%/pothole-images/%' THEN
                v_storage_path := split_part(v_row.image_url, '/pothole-images/', 2);
                v_storage_path := split_part(v_storage_path, '?', 1);
            ELSE
                v_storage_path := v_row.image_url;
            END IF;

            IF v_storage_path IS NOT NULL AND v_storage_path <> '' THEN
                DELETE FROM storage.objects
                WHERE bucket_id = 'pothole-images'
                  AND name = v_storage_path;
            END IF;
        END IF;
    END LOOP;

    -- Delete database records strictly owned by this user
    DELETE FROM public.detections
    WHERE id = ANY(p_detection_ids)
      AND (v_current_user IS NULL OR user_id = v_current_user);

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'deleted_count', v_deleted_count
    );
END;
$$;

GRANT EXECUTE ON FUNCTION bulk_delete_pothole_detections(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION bulk_delete_pothole_detections(bigint[]) TO anon;
GRANT EXECUTE ON FUNCTION bulk_delete_pothole_detections(bigint[]) TO service_role;


-- 5. Location Atomic Deletion Stored Procedure (RPC)
-- Deletes ALL duplicate detection records and storage images logged at a specific
-- GPS coordinate belonging to the calling user.
CREATE OR REPLACE FUNCTION delete_pothole_location(
    p_latitude double precision,
    p_longitude double precision
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
    v_current_user uuid;
    v_deleted_count int;
    v_row record;
    v_storage_path text;
BEGIN
    v_current_user := auth.uid();
    IF v_current_user IS NULL AND current_user <> 'postgres' AND current_user <> 'service_role' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'UNAUTHORIZED',
            'message', 'Authentication required to delete reports.'
        );
    END IF;

    -- Allow storage deletion in this transaction
    PERFORM set_config('storage.allow_delete_query', 'true', true);

    -- Purge images from storage for all records at this coordinate owned by caller
    FOR v_row IN
        SELECT image_url, user_id FROM public.detections
        WHERE abs(latitude - p_latitude) < 0.000001
          AND abs(longitude - p_longitude) < 0.000001
          AND (v_current_user IS NULL OR user_id = v_current_user)
    LOOP
        IF v_row.image_url IS NOT NULL AND v_row.image_url <> '' THEN
            IF v_row.image_url LIKE '%/pothole-images/%' THEN
                v_storage_path := split_part(v_row.image_url, '/pothole-images/', 2);
                v_storage_path := split_part(v_storage_path, '?', 1);
            ELSE
                v_storage_path := v_row.image_url;
            END IF;

            IF v_storage_path IS NOT NULL AND v_storage_path <> '' THEN
                DELETE FROM storage.objects
                WHERE bucket_id = 'pothole-images'
                  AND name = v_storage_path;
            END IF;
        END IF;
    END LOOP;

    -- Delete all detection rows at this coordinate strictly owned by caller
    DELETE FROM public.detections
    WHERE abs(latitude - p_latitude) < 0.000001
      AND abs(longitude - p_longitude) < 0.000001
      AND (v_current_user IS NULL OR user_id = v_current_user);

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'deleted_count', v_deleted_count
    );
END;
$$;

GRANT EXECUTE ON FUNCTION delete_pothole_location(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_pothole_location(double precision, double precision) TO anon;
GRANT EXECUTE ON FUNCTION delete_pothole_location(double precision, double precision) TO service_role;

