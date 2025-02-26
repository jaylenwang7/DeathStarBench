{{- define "hotelreservation.templates.baseDeploymentMongoDB" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    {{- include "hotel-reservation.labels" . | nindent 4 }}
    {{- include "hotel-reservation.backendLabels" . | nindent 4 }}
    service: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
  name: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
spec:
  replicas: {{ .Values.replicas | default .Values.global.replicas }}
  selector:
    matchLabels:
      {{- include "hotel-reservation.selectorLabels" . | nindent 6 }}
      {{- include "hotel-reservation.backendLabels" . | nindent 6 }}
      service: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
      app: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
  template:
    metadata:
      labels:
        {{- include "hotel-reservation.labels" . | nindent 8 }}
        {{- include "hotel-reservation.backendLabels" . | nindent 8 }}
        service: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
        app: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
      {{- if hasKey $.Values "annotations" }}
      annotations:
        {{ tpl $.Values.annotations . | nindent 8 | trim }}
      {{- else if hasKey $.Values.global "annotations" }}
      annotations:
        {{ tpl $.Values.global.annotations . | nindent 8 | trim }}
      {{- end }}
    spec:
      containers:
      - name: "mongodb"
        image: jaylenwang/hotel-mongodb:5.0
        imagePullPolicy: {{ .Values.container.imagePullPolicy | default $.Values.global.imagePullPolicy }}
        env:
        - name: DB_TYPE
          value: "{{ $.Values.dbType | default (trimPrefix "mongodb-" $.Values.name) }}-db"
        ports:
        {{- range $cport := .Values.container.ports }}
        - containerPort: {{ $cport.containerPort -}}
        {{ end }}
        readinessProbe:
          exec:
            command:
            - bash
            - -c
            - 'mongo --eval "db.getSiblingDB(''{{ $.Values.dbType | default (trimPrefix "mongodb-" $.Values.name) }}-db'').stats().ok" | grep -q "^1"'
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 2
          failureThreshold: 10
        livenessProbe:
          exec:
            command:
            - mongo
            - --eval
            - "db.adminCommand('ping')"
          initialDelaySeconds: 30
          periodSeconds: 10
        {{- if .Values.container.resources }}
        resources:
          {{ tpl .Values.container.resources $ | nindent 10 | trim }}
        {{- else if hasKey $.Values.global "resources" }}
        resources:
          {{ tpl $.Values.global.resources $ | nindent 10 | trim }}
        {{- end }}
        volumeMounts:
        - mountPath: /data/db
          name: {{ $.Values.name }}-{{ include "hotel-reservation.fullname" $ }}-path
      volumes:
      - name: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}-path
        {{- if $.Values.global.mongodb.persistentVolume.enabled }}
        persistentVolumeClaim:
          claimName: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}-pvc
        {{- else }}
        emptyDir: {}
        {{- end }}
      {{- if hasKey .Values "topologySpreadConstraints" }}
      topologySpreadConstraints:
        {{ tpl .Values.topologySpreadConstraints . | nindent 6 | trim }}
      {{- else if hasKey $.Values.global.mongodb "topologySpreadConstraints" }}
      topologySpreadConstraints:
        {{ tpl $.Values.global.mongodb.topologySpreadConstraints . | nindent 6 | trim }}
      {{- end }}
      hostname: {{ .Values.name }}-{{ include "hotel-reservation.fullname" . }}
      restartPolicy: {{ .Values.restartPolicy | default .Values.global.restartPolicy}}
      {{- if .Values.affinity }}
      affinity: {{- toYaml .Values.affinity | nindent 8 }}
      {{- else if hasKey $.Values.global "affinity" }}
      affinity: {{- toYaml .Values.global.affinity | nindent 8 }}
      {{- end }}
      {{- if .Values.tolerations }}
      tolerations: {{- toYaml .Values.tolerations | nindent 8 }}
      {{- else if hasKey $.Values.global "tolerations" }}
      tolerations: {{- toYaml .Values.global.tolerations | nindent 8 }}
      {{- end }}
      {{- if .Values.nodeSelector }}
      nodeSelector: {{- toYaml .Values.nodeSelector | nindent 8 }}
      {{- else if hasKey $.Values.global "nodeSelector" }}
      nodeSelector: {{- toYaml .Values.global.nodeSelector | nindent 8 }}
      {{- end }}
{{- end}}