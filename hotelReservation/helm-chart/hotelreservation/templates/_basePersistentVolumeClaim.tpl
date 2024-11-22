{{- define "hotelreservation.templates.basePersistentVolumeClaim" }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.name }}-pvc
  labels:
    app: {{ .Values.name }}
spec:
  {{- if and .Values.global.mongodb.persistentVolume.pvprovisioner.enabled .Values.global.mongodb.persistentVolume.pvprovisioner.storageClassName }}
  storageClassName: {{ .Values.global.mongodb.persistentVolume.pvprovisioner.storageClassName }}
  {{- else }}
  storageClassName: ""  # Important for static binding with hostPath PV
  {{- end }}
  accessModes:
    - ReadWriteOnce
  {{- if .Values.global.mongodb.persistentVolume.hostPath.enabled }}
  volumeName: {{ .Values.name }}-pv  # Static binding to the PV
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.global.mongodb.persistentVolume.size }}
{{- end }}