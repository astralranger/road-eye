import os
from datetime import datetime, timedelta
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

# Use SERVICE_ROLE_KEY to bypass RLS
URL = os.getenv("SUPABASE_URL")
KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
supabase: Client = create_client(URL, KEY)

def deep_cleanup(days=30):
    # 1. Calculate the cutoff date in Python (ISO format)
    cutoff_date = (datetime.now() - timedelta(days=days)).isoformat()
    
    print(f"🧹 Starting cleanup of data older than {days} days (Before {cutoff_date})...")

    try:
        # 2. Find old detections and their images
        # We fetch the IDs and URLs of data older than our calculated date
        response = supabase.table("detections") \
            .select("id, image_url") \
            .lt("created_at", cutoff_date) \
            .execute()
        
        old_records = response.data

        if not old_records:
            print("✅ No old detections found in database.")
        else:
            # 3. Extract filenames from URLs for storage deletion
            # Example URL: .../pothole-images/ph_20240101_123456.jpg
            filenames = []
            for record in old_records:
                if record['image_url']:
                    # Get the part after the last slash
                    fname = record['image_url'].split('/')[-1]
                    filenames.append(fname)

            # 4. Delete images from Storage Bucket
            if filenames:
                print(f"🗑️  Deleting {len(filenames)} images from 'pothole-images' bucket...")
                # Note: .remove() expects a list of paths
                storage_response = supabase.storage.from_("pothole-images").remove(filenames)
                print(f"✅ Storage cleanup response: {storage_response}")

            # 5. Delete rows from Database
            # We delete from complaints first if they exist (due to foreign key)
            print("🗑️  Deleting database records from 'pothole_complaints'...")
            supabase.table("pothole_complaints").delete().lt("created_at", cutoff_date).execute()
            
            print("🗑️  Deleting database records from 'detections'...")
            supabase.table("detections").delete().lt("created_at", cutoff_date).execute()

        # 6. Cleanup telemetry (road_logs) - usually the largest table
        print("🗑️  Cleaning up telemetry logs from 'road_logs'...")
        log_response = supabase.table("road_logs").delete().lt("created_at", cutoff_date).execute()
        print(f"✅ Deleted old telemetry entries.")

        print("\n✨ Cleanup process finished successfully!")

    except Exception as e:
        print(f"❌ Cleanup failed with error: {e}")

if __name__ == "__main__":
    # You can change 30 to 0 if you want to delete EVERYTHING for a fresh start
    deep_cleanup(days=30)