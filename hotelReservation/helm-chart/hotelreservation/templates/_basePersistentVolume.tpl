{{- define "hotelreservation.templates.basePersistentVolume" }}
{{- if .Values.global.mongodb.persistentVolume.hostPath.enabled }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .Values.name }}-pv
  labels:
    app: {{ .Values.name }}
    type: mongodb-storage
spec:
  capacity:
    storage: {{ .Values.global.mongodb.persistentVolume.size }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""  # Important for static binding
  hostPath:
    path: {{ .Values.global.mongodb.persistentVolume.hostPath.path }}/{{ .Values.name }}-data
    type: DirectoryOrCreate
{{- end }}
{{- end }}