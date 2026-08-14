package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"time"
)

type Result struct {
	Sensor  string  `json:"sensor"`
	Value   float64 `json:"value"`
	Average float64 `json:"average"`
	Anomaly bool    `json:"anomaly"`
}

func main() {
	threshold := 5.0

	if t := os.Getenv("ANOMALY_THRESHOLD"); t != "" {
		if parsed, err := strconv.ParseFloat(t, 64); err == nil {
			threshold = parsed
		}
	}

	var values []float64

	for {
		// Simulated temperature sensor
		value := 20 + rand.Float64()*5

		// Occasionally inject an unusual value
		if rand.Intn(10) == 0 {
			value += 15
		}

		values = append(values, value)

		if len(values) > 5 {
			values = values[1:]
		}

		var sum float64
		for _, v := range values {
			sum += v
		}

		average := sum / float64(len(values))

		result := Result{
			Sensor:  "temperature",
			Value:   value,
			Average: average,
			Anomaly: value-average > threshold,
		}

		data, _ := json.Marshal(result)
		fmt.Println(string(data))

		time.Sleep(time.Second)
	}
}
