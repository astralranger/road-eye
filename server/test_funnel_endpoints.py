import io
import json
import requests

def test_endpoints():
    base_url = "http://127.0.0.1:8000"
    
    # 1. Test GET /health
    print("Testing GET /health...")
    resp = requests.get(f"{base_url}/health", timeout=5)
    print(f"Status: {resp.status_code}")
    print(f"Response: {resp.json()}")
    assert resp.status_code == 200
    assert resp.json().get("status") == "ok"
    print(">>> GET /health passed!\n")

    # 2. Test POST /upload-video
    print("Testing POST /upload-video...")
    fake_mp4_bytes = b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2avc1mp41" + b"\x00" * 1024
    files = {
        "video": ("probe_sample.mp4", io.BytesIO(fake_mp4_bytes), "video/mp4")
    }
    data = {
        "telemetry": json.dumps({
            "report_id": "probe_test_job_101",
            "user_id": "test_developer",
            "distance_meters": 15.0,
            "device_model": "Test_Device"
        })
    }
    
    resp_upload = requests.post(f"{base_url}/upload-video", files=files, data=data, timeout=10)
    print(f"Status: {resp_upload.status_code}")
    print(f"Response: {resp_upload.json()}")
    assert resp_upload.status_code == 202
    assert resp_upload.json().get("success") is True
    print(">>> POST /upload-video passed!\n")

    # 3. Test POST /api/v1/spatial/upload (mobile client path)
    print("Testing POST /api/v1/spatial/upload...")
    files2 = {
        "file": ("mobile_sample.mp4", io.BytesIO(fake_mp4_bytes), "video/mp4")
    }
    data2 = {
        "metadata": json.dumps({
            "report_id": "mobile_test_job_202",
            "user_id": "mobile_client_tester",
            "distance_meters": 20.0
        })
    }
    resp_mobile = requests.post(f"{base_url}/api/v1/spatial/upload", files=files2, data=data2, timeout=10)
    print(f"Status: {resp_mobile.status_code}")
    print(f"Response: {resp_mobile.json()}")
    assert resp_mobile.status_code == 202
    assert resp_mobile.json().get("success") is True
    print(">>> POST /api/v1/spatial/upload passed!\n")

if __name__ == "__main__":
    test_endpoints()
