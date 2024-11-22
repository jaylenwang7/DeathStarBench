{{- define "hotelreservation.templates.basePersistentVolumeClaim" }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.name }}-pvc
  annotations:
    "helm.sh/hook": "pre-install"
    "helm.sh/hook-weight": "0"
spec:
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  {{- if .Values.global.mongodb.persistentVolume.pvprovisioner.enabled }}
  {{- if .Values.global.mongodb.persistentVolume.pvprovisioner.storageClassName }}
  storageClassName: {{ .Values.global.mongodb.persistentVolume.pvprovisioner.storageClassName }}
  {{- end }}
  {{- else }}
  storageClassName: manual
  selector:
    matchLabels:
      app-name: {{ .Values.name }}
      type: local
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.global.mongodb.persistentVolume.size }}
{{- end }}