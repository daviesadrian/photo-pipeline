import os

os.environ["THUMBNAILS_BUCKET"] = "cloud-portfolio-789-thumbnails"

from cloudevents.http import CloudEvent

from main import process_photo

attributes = {
    "type": "google.cloud.storage.object.v1.finalized",
    "source": "//storage.googleapis.com/projects/_/buckets/cloud-portfolio-789-uploads",
}
data = {
    "bucket": "cloud-portfolio-789-uploads",
    "name": "test-photo.jpg",
    "contentType": "image/jpeg",
}

event = CloudEvent(attributes, data)
process_photo(event)
print("Local test complete.")
