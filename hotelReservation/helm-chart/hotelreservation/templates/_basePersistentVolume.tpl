{{- define "hotelreservation.templates.basePersistentVolume" }}
{{- if .Values.global.mongodb.persistentVolume.hostPath.enabled }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .Values.name }}-pv
  labels:
    app-name: {{ .Values.name }}
    type: local
  annotations:
    "helm.sh/hook": "pre-install"
    "helm.sh/hook-weight": "-5"
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  capacity:
    storage: {{ .Values.global.mongodb.persistentVolume.size }}
  storageClassName: manual
  hostPath:
    path: {{ .Values.global.mongodb.persistentVolume.hostPath.path }}/{{ .Values.name }}-pv
    type: DirectoryOrCreate
{{- end }}
{{- end }}