{{- define "socialnetwork.templates.baseDeployment" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    service: {{ .Values.name }}
  name: {{ .Values.name }}
spec: 
  replicas: {{ .Values.replicas | default .Values.global.replicas }}
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
        {{- if .env }}
        {{- if not .disableReadinessProbe }}
        readinessProbe:
          tcpSocket:
            port: {{ .probePort | default (index .ports 0).containerPort }}
          initialDelaySeconds: {{ .probeInitialDelay | default $.Values.global.probe.initialDelaySeconds }}
          periodSeconds: {{ .probePeriodSeconds | default $.Values.global.probe.periodSeconds }}
          failureThreshold: {{ .probeFailureThreshold | default $.Values.global.probe.failureThreshold }}
          timeoutSeconds: {{ .probeTimeoutSeconds | default $.Values.global.probe.timeoutSeconds }}
        {{- end }}
        {{- if or .lifecycle $.Values.global.lifecycle }}
        lifecycle:
          {{- if .lifecycle }}
          {{- if and .lifecycle.preStop .lifecycle.preStop.enabled }}
          preStop:
            exec:
              command: {{ .lifecycle.preStop.exec.command | toYaml | nindent 14 }}
          {{- end }}
          {{- else if and $.Values.global.lifecycle $.Values.global.lifecycle.preStop }}
          preStop:
            exec:
              command: {{ $.Values.global.lifecycle.preStop.exec.command | toYaml | nindent 14 }}
          {{- end }}
        {{- end }}
        terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default $.Values.global.terminationGracePeriodSeconds | default 30 }}
        env:
        {{- range $e := .env}}
        - name: {{ $e.name }}
          value: "{{ (tpl ($e.value | toString) $) }}"
        {{ end -}}
        {{ end -}}
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
          {{ tpl .resources . | nindent 6 | trim }}
        {{- else if hasKey $.Values.global "resources" }}           
        resources:
          {{ tpl $.Values.global.resources $ | nindent 6 | trim }}
        {{- end }}  
        {{- if $.Values.configMaps }}        
        volumeMounts: 
        {{- range $configMap := $.Values.configMaps }}
        - name: {{ $.Values.name }}-config
          mountPath: {{ $configMap.mountPath }}
          subPath: {{ $configMap.name }}
        {{- end }}
        {{- end }}
      {{- end -}}
      {{- if $.Values.configMaps }}
      volumes:
      - name: {{ $.Values.name }}-config
        configMap:
          name: {{ $.Values.name }}
      {{- end }}
      {{- if hasKey .Values "topologySpreadConstraints" }}
      topologySpreadConstraints:
        {{ tpl .Values.topologySpreadConstraints . | nindent 6 | trim }}
      {{- else if hasKey $.Values.global  "topologySpreadConstraints" }}
      topologySpreadConstraints:
        {{ tpl $.Values.global.topologySpreadConstraints . | nindent 6 | trim }}
      {{- end }}
      hostname: {{ $.Values.name }}
      restartPolicy: {{ .Values.restartPolicy | default .Values.global.restartPolicy}}

  {{- end}}
