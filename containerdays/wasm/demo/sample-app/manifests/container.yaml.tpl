apiVersion: apps/v1
kind: Deployment
metadata:
  name: container-webserver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: container-webserver
  template:
    metadata:
      labels:
        app: container-webserver
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: container-webserver
          image: localhost:4000/sample-app-container:${IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
