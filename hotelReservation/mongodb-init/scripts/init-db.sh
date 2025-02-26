#!/bin/bash
set -e

DB_TYPE=${DB_TYPE:-"reservation-db"}

echo "Initializing $DB_TYPE database..."

case "$DB_TYPE" in
    "reservation-db")
        mongo <<EOF_MONGO
        use reservation-db;
        db.reservation.insertOne({
            "hotelId": "4", 
            "customerName": "Alice", 
            "inDate": "2015-04-09", 
            "outDate": "2015-04-10", 
            "number": 1
        });
        db.number.insertMany([
            {"hotelId": "1", "number": 200},
            {"hotelId": "2", "number": 200},
            {"hotelId": "3", "number": 200},
            {"hotelId": "4", "number": 200},
            {"hotelId": "5", "number": 200},
            {"hotelId": "6", "number": 200}
        ]);
        
        // Add more hotel rooms
        let moreRooms = [];
        for (let i = 7; i <= 80; i++) {
            let hotelID = i.toString();
            let roomNumber = 200;
            if (i % 3 == 1) roomNumber = 300;
            else if (i % 3 == 2) roomNumber = 250;
            
            moreRooms.push({"hotelId": hotelID, "number": roomNumber});
        }
        
        if (moreRooms.length > 0) {
            db.number.insertMany(moreRooms);
        }
EOF_MONGO
        ;;
    "profile-db")
        mongo <<EOF_MONGO
        use profile-db;
        db.hotels.insertMany([
            {
                "id": "1",
                "name": "Clift Hotel",
                "phoneNumber": "(415) 775-4700",
                "description": "A 6-minute walk from Union Square and 4 minutes from a Muni Metro station, this luxury hotel designed by Philippe Starck features an artsy furniture collection in the lobby, including work by Salvador Dali.",
                "address": {
                    "streetNumber": "495",
                    "streetName": "Geary St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94102",
                    "lat": 37.7867,
                    "lon": -122.4112
                }
            },
            {
                "id": "2",
                "name": "W San Francisco",
                "phoneNumber": "(415) 777-5300",
                "description": "Less than a block from the Yerba Buena Center for the Arts, this trendy hotel is a 12-minute walk from Union Square.",
                "address": {
                    "streetNumber": "181",
                    "streetName": "3rd St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94103",
                    "lat": 37.7854,
                    "lon": -122.4005
                }
            },
            {
                "id": "3",
                "name": "Hotel Zetta",
                "phoneNumber": "(415) 543-8555",
                "description": "A 3-minute walk from the Powell Street cable-car turnaround and BART rail station, this hip hotel 9 minutes from Union Square combines high-tech lodging with artsy touches.",
                "address": {
                    "streetNumber": "55",
                    "streetName": "5th St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94103",
                    "lat": 37.7834,
                    "lon": -122.4071
                }
            },
            {
                "id": "4",
                "name": "Hotel Vitale",
                "phoneNumber": "(415) 278-3700",
                "description": "This waterfront hotel with Bay Bridge views is 3 blocks from the Financial District and a 4-minute walk from the Ferry Building.",
                "address": {
                    "streetNumber": "8",
                    "streetName": "Mission St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94105",
                    "lat": 37.7936,
                    "lon": -122.3930
                }
            },
            {
                "id": "5",
                "name": "Phoenix Hotel",
                "phoneNumber": "(415) 776-1380",
                "description": "Located in the Tenderloin neighborhood, a 10-minute walk from a BART rail station, this retro motor lodge has hosted many rock musicians and other celebrities since the 1950s. It's a 4-minute walk from the historic Great American Music Hall nightclub.",
                "address": {
                    "streetNumber": "601",
                    "streetName": "Eddy St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94109",
                    "lat": 37.7831,
                    "lon": -122.4181
                }
            },
            {
                "id": "6",
                "name": "St. Regis San Francisco",
                "phoneNumber": "(415) 284-4000",
                "description": "St. Regis Museum Tower is a 42-story, 484 ft skyscraper in the South of Market district of San Francisco, California, adjacent to Yerba Buena Gardens, Moscone Center, PacBell Building and the San Francisco Museum of Modern Art.",
                "address": {
                    "streetNumber": "125",
                    "streetName": "3rd St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94109",
                    "lat": 37.7863,
                    "lon": -122.4015
                }
            }
        ]);
        
        // Add more hotels
        for (let i = 7; i <= 80; i++) {
            let hotelID = i.toString();
            let phoneNumber = "(415) 284-40" + hotelID;
            
            let lat = 37.7835 + (i/500.0*3);
            let lon = -122.41 + (i/500.0*4);
            
            db.hotels.insertOne({
                "id": hotelID,
                "name": "St. Regis San Francisco",
                "phoneNumber": phoneNumber,
                "description": "St. Regis Museum Tower is a 42-story, 484 ft skyscraper in the South of Market district of San Francisco, California, adjacent to Yerba Buena Gardens, Moscone Center, PacBell Building and the San Francisco Museum of Modern Art.",
                "address": {
                    "streetNumber": "125",
                    "streetName": "3rd St",
                    "city": "San Francisco",
                    "state": "CA",
                    "country": "United States",
                    "postalCode": "94109",
                    "lat": lat,
                    "lon": lon
                }
            });
        }
EOF_MONGO
        ;;
    "geo-db")
        mongo <<EOF_MONGO
        use geo-db;
        db.geo.insertMany([
            {"hotelId": "1", "lat": 37.7867, "lon": -122.4112},
            {"hotelId": "2", "lat": 37.7854, "lon": -122.4005},
            {"hotelId": "3", "lat": 37.7854, "lon": -122.4071},
            {"hotelId": "4", "lat": 37.7936, "lon": -122.3930},
            {"hotelId": "5", "lat": 37.7831, "lon": -122.4181},
            {"hotelId": "6", "lat": 37.7863, "lon": -122.4015}
        ]);
        
        // Add more geo points
        let morePoints = [];
        for (let i = 7; i <= 80; i++) {
            let hotelID = i.toString();
            let lat = 37.7835 + (i/500.0*3);
            let lon = -122.41 + (i/500.0*4);
            
            morePoints.push({"hotelId": hotelID, "lat": lat, "lon": lon});
        }
        
        if (morePoints.length > 0) {
            db.geo.insertMany(morePoints);
        }
EOF_MONGO
        ;;
    "rate-db")
        mongo <<EOF_MONGO
        use rate-db;
        db.inventory.insertMany([
            {
                "hotelId": "1",
                "code": "RACK",
                "inDate": "2015-04-09",
                "outDate": "2015-04-10",
                "roomType": {
                    "bookableRate": 109.00,
                    "code": "KNG",
                    "roomDescription": "King sized bed",
                    "totalRate": 109.00,
                    "totalRateInclusive": 123.17
                }
            },
            {
                "hotelId": "2",
                "code": "RACK",
                "inDate": "2015-04-09",
                "outDate": "2015-04-10",
                "roomType": {
                    "bookableRate": 139.00,
                    "code": "QN",
                    "roomDescription": "Queen sized bed",
                    "totalRate": 139.00,
                    "totalRateInclusive": 153.09
                }
            },
            {
                "hotelId": "3",
                "code": "RACK",
                "inDate": "2015-04-09",
                "outDate": "2015-04-10",
                "roomType": {
                    "bookableRate": 109.00,
                    "code": "KNG",
                    "roomDescription": "King sized bed",
                    "totalRate": 109.00,
                    "totalRateInclusive": 123.17
                }
            }
        ]);
        
        // Add more rate plans
        let morePlans = [];
        for (let i = 7; i <= 80; i++) {
            if (i % 3 != 0) {
                continue;
            }

            let hotelID = i.toString();

            let endDate = "2015-04-";
            if (i % 2 == 0) {
                endDate = endDate + "17";
            } else {
                endDate = endDate + "24";
            }

            let rate = 109.00;
            let rateInc = 123.17;
            if (i % 5 == 1) {
                rate = 120.00;
                rateInc = 140.00;
            } else if (i % 5 == 2) {
                rate = 124.00;
                rateInc = 144.00;
            } else if (i % 5 == 3) {
                rate = 132.00;
                rateInc = 158.00;
            } else if (i % 5 == 4) {
                rate = 232.00;
                rateInc = 258.00;
            }

            morePlans.push({
                "hotelId": hotelID,
                "code": "RACK",
                "inDate": "2015-04-09",
                "outDate": endDate,
                "roomType": {
                    "bookableRate": rate,
                    "code": "KNG",
                    "roomDescription": "King sized bed",
                    "totalRate": rate,
                    "totalRateInclusive": rateInc
                }
            });
        }
        
        if (morePlans.length > 0) {
            db.inventory.insertMany(morePlans);
        }
EOF_MONGO
        ;;
    "recommendation-db")
        mongo <<EOF_MONGO
        use recommendation-db;
        db.recommendation.insertMany([
            {"hotelId": "1", "lat": 37.7867, "lon": -122.4112, "rate": 109.00, "price": 150.00},
            {"hotelId": "2", "lat": 37.7854, "lon": -122.4005, "rate": 139.00, "price": 120.00},
            {"hotelId": "3", "lat": 37.7834, "lon": -122.4071, "rate": 109.00, "price": 190.00},
            {"hotelId": "4", "lat": 37.7936, "lon": -122.3930, "rate": 129.00, "price": 160.00},
            {"hotelId": "5", "lat": 37.7831, "lon": -122.4181, "rate": 119.00, "price": 140.00},
            {"hotelId": "6", "lat": 37.7863, "lon": -122.4015, "rate": 149.00, "price": 200.00}
        ]);
        
        // Add more hotel recommendations
        let moreHotels = [];
        for (let i = 7; i <= 80; i++) {
            let rate = 135.00;
            let rateInc = 179.00;
            
            if (i % 3 == 0) {
                switch (i % 5) {
                    case 1:
                        rate = 120.00;
                        rateInc = 140.00;
                        break;
                    case 2:
                        rate = 124.00;
                        rateInc = 144.00;
                        break;
                    case 3:
                        rate = 132.00;
                        rateInc = 158.00;
                        break;
                    case 4:
                        rate = 232.00;
                        rateInc = 258.00;
                        break;
                    default:
                        rate = 109.00;
                        rateInc = 123.17;
                }
            }
            
            let hotelID = i.toString();
            let lat = 37.7835 + (i/500.0*3);
            let lon = -122.41 + (i/500.0*4);
            
            moreHotels.push({"hotelId": hotelID, "lat": lat, "lon": lon, "rate": rate, "price": rateInc});
        }
        
        if (moreHotels.length > 0) {
            db.recommendation.insertMany(moreHotels);
        }
EOF_MONGO
        ;;
    "user-db")
        mongo <<EOF_MONGO
        use user-db;
        
        // Helper function to create SHA-256 hashed passwords
        function sha256(password) {
            var crypto = require('crypto');
            return crypto.createHash('sha256').update(password).digest('hex');
        }
        
        let users = [];
        for (let i = 0; i <= 500; i++) {
            let suffix = i.toString();
            // Convert suffix to hex format for username
            let hexSuffix = i.toString(16);
            
            let password = "";
            for (let j = 0; j < 10; j++) {
                password += suffix;
            }
            
            users.push({
                "username": "Cornell_" + hexSuffix,
                "password": sha256(password)
            });
        }
        
        db.user.insertMany(users);
EOF_MONGO
        ;;
    *)
        echo "Unknown database type: $DB_TYPE"
        exit 1
        ;;
esac

echo "$DB_TYPE initialization completed successfully."