{{- define "hotelreservation.templates.baseDeploymentMongoDB" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    service: {{ .Values.name }}
    app: {{ .Values.name }}
  name: {{ .Values.name }}
spec:
  replicas: {{ .Values.replicas | default .Values.global.replicas }}
  strategy:
    type: Recreate  # Required for stable storage handling
  selector:
    matchLabels:
      service: {{ .Values.name }}
  template:
    metadata:
      labels:
        service: {{ .Values.name }}
        app: {{ .Values.name }}
    spec:
      containers:
      {{- with .Values.container }}
      - name: "{{ .name }}"
        image: {{ .dockerRegistry | default $.Values.global.dockerRegistry }}/{{ .image }}:{{ .imageVersion | default $.Values.global.defaultImageVersion }}
        imagePullPolicy: {{ .imagePullPolicy | default $.Values.global.imagePullPolicy }}
        ports:
        {{- range $cport := .ports }}
        - containerPort: {{ $cport.containerPort -}}
        {{ end }}
        {{- if .command}}
        command:
        - {{ .command }}
        {{- end -}}
        {{- if .args}}
        args:
        {{- range $arg := .args}}
        - {{ $arg }}
        {{- end -}}
        {{- end }}
        {{- if .resources }}
        resources:
          {{ tpl .resources $ | nindent 6 | trim }}
        {{- else if hasKey $.Values.global "resources" }}
        resources:
          {{ tpl $.Values.global.resources $ | nindent 6 | trim }}
        {{- end }}
        {{- if $.Values.global.mongodb.persistentVolume.hostPath.enabled }}
        volumeMounts:
        - mountPath: /data/db
          name: {{ $.Values.name }}-data
        {{- end }}
      {{- end }}
      volumes:
      - name: {{ .Values.name }}-data
        persistentVolumeClaim:
          claimName: {{ .Values.name }}-pvc
      hostname: {{ $.Values.name }}
      restartPolicy: {{ .Values.restartPolicy | default .Values.global.restartPolicy}}
{{- end}}