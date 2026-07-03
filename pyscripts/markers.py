import cv2
d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11)
for marker_id in [4, 8, 12, 14, 20]:
    img = cv2.aruco.generateImageMarker(d, marker_id, 400)
    cv2.imwrite(f"tag_{marker_id}.png", img)
print("Generated 5 marker PNGs.")
