import os
from datetime import datetime, timezone
from io import BytesIO

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import firestore, storage
from PIL import Image

THUMBNAILS_BUCKET = os.environ["THUMBNAILS_BUCKET"]
THUMBNAIL_SIZE = (200, 200)

storage_client = storage.Client()
db = firestore.Client()


@functions_framework.cloud_event
def process_photo(cloud_event: CloudEvent):
    data = cloud_event.data
    bucket_name = data["bucket"]
    file_name = data["name"]
    content_type = data.get("contentType", "")

    if not content_type.startswith("image/"):
        print(f"Skipping non-image file: {file_name} ({content_type})")
        return

    source_bucket = storage_client.bucket(bucket_name)
    source_blob = source_bucket.blob(file_name)
    image_bytes = source_blob.download_as_bytes()

    image = Image.open(BytesIO(image_bytes))
    image.thumbnail(THUMBNAIL_SIZE)

    thumb_buffer = BytesIO()
    image_format = image.format or "JPEG"
    image.save(thumb_buffer, format=image_format)
    thumb_buffer.seek(0)

    thumb_bucket = storage_client.bucket(THUMBNAILS_BUCKET)
    thumb_blob_name = f"thumb-{file_name}"
    thumb_blob = thumb_bucket.blob(thumb_blob_name)
    thumb_blob.upload_from_file(thumb_buffer, content_type=content_type)

    db.collection("images").document(file_name.replace("/", "_")).set(
        {
            "original_file": file_name,
            "thumbnail_file": thumb_blob_name,
            "thumbnail_url": f"https://storage.googleapis.com/{THUMBNAILS_BUCKET}/{thumb_blob_name}",
            "content_type": content_type,
            "size_bytes": len(image_bytes),
            "processed_at": datetime.now(timezone.utc).isoformat(),
        }
    )

    print(f"Processed {file_name} -> {thumb_blob_name}")
