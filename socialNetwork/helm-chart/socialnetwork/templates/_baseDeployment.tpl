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
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default $.Values.global.terminationGracePeriodSeconds | default 30 }}
      containers:
      {{- with .Values.container }}
      - name: "{{ .name }}"
        image: {{ .image.registry | default $.Values.global.dockerRegistry }}/{{ .image.repository | default $.Values.global.repository }}/{{ .image.name | default $.Values.global.imageName }}:{{ .image.tag | default $.Values.global.defaultImageVersion }}
        imagePullPolicy: {{ .imagePullPolicy | default $.Values.global.imagePullPolicy }}
        ports:
        {{- range $cport := .ports }}
        - containerPort: {{ $cport.containerPort -}}
        {{ end }} 
        {{- if not .disableReadinessProbe }}
        readinessProbe:
          {{- if .readinessProbe }}
          {{- if .readinessProbe.exec }}
          exec:
            command:
            {{- range $cmd := .readinessProbe.exec.command }}
            - {{ $cmd }}
            {{- end }}
          {{- else if .readinessProbe.httpGet }}
          httpGet:
            path: {{ .readinessProbe.httpGet.path }}
            port: {{ .readinessProbe.httpGet.port }}
            {{- if .readinessProbe.httpGet.scheme }}
            scheme: {{ .readinessProbe.httpGet.scheme }}
            {{- end }}
            {{- if .readinessProbe.httpGet.httpHeaders }}
            httpHeaders:
            {{- range $header := .readinessProbe.httpGet.httpHeaders }}
            - name: {{ $header.name }}
              value: {{ $header.value }}
            {{- end }}
            {{- end }}
          {{- else }}
          tcpSocket:
            port: {{ .probePort | default (index .ports 0).containerPort }}
          {{- end }}
          {{- else }}
          tcpSocket:
            port: {{ .probePort | default (index .ports 0).containerPort }}
          {{- end }}
          initialDelaySeconds: {{ .readinessProbe.initialDelaySeconds | default .probeInitialDelay | default $.Values.global.probe.initialDelaySeconds }}
          periodSeconds: {{ .readinessProbe.periodSeconds | default .probePeriodSeconds | default $.Values.global.probe.periodSeconds }}
          failureThreshold: {{ .readinessProbe.failureThreshold | default .probeFailureThreshold | default $.Values.global.probe.failureThreshold }}
          timeoutSeconds: {{ .readinessProbe.timeoutSeconds | default .probeTimeoutSeconds | default $.Values.global.probe.timeoutSeconds }}
          {{- if .readinessProbe.successThreshold }}
          successThreshold: {{ .readinessProbe.successThreshold }}
          {{- end }}
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
        {{- if .env }}
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