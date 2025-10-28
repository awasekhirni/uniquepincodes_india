-- ################################################################################################################################################################################################################################################
-- INDIA POST ONTOLOGY SCHEMA
-- Copyright 2025 β ORI Inc.Canada All Rights Reserved.
-- Author: Awase Khirni Syed
-- A comprehensive placename ontology integrated with Indian post office data
-- ##################################################################################

-- Create schema for India Post data
CREATE SCHEMA IF NOT EXISTS india_post
    AUTHORIZATION pg_database_owner;

COMMENT ON SCHEMA india_post
    IS 'Ontology schema for Indian post offices and placenames. Stores structured postal data with geographic, administrative, and linguistic attributes.';

GRANT USAGE ON SCHEMA india_post TO PUBLIC;
GRANT ALL ON SCHEMA india_post TO pg_database_owner;


-- -##################################################################################
-- EXTENSIONS
-- ##################################################################################


CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


-- ##################################################################################
-- TABLE: administrative_level (types of places in ontology)
-- ##################################################################################


CREATE TABLE india_post.administrative_level (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    level_name TEXT NOT NULL UNIQUE -- e.g., Country, State, District, City
);

-- Insert standard levels
INSERT INTO india_post.administrative_level (level_name) VALUES
    ('Country'),
    ('State'),
    ('District'),
    ('City'),
    ('Town'),
    ('Village'),
    ('Post Office'),
    ('Landmark')
ON CONFLICT (level_name) DO NOTHING;


-- -----------------------------------------------------------------------------
-- TABLE: language (for multilingual support)
-- -----------------------------------------------------------------------------


CREATE TABLE india_post.language (
    code VARCHAR(10) PRIMARY KEY,
    name_english TEXT NOT NULL,
    name_native TEXT
);

INSERT INTO india_post.language (code, name_english, name_native) VALUES
    ('en', 'English', 'English'),
    ('hi', 'Hindi', 'हिन्दी'),
    ('as', 'Assamese', 'অসমীয়া'),
    ('bn', 'Bengali', 'বাংলা'),
    ('te', 'Telugu', 'తెలుగు'),
    ('ta', 'Tamil', 'தமிழ்'),
    ('ml', 'Malayalam', 'മലയാളം'),
    ('kn', 'Kannada', 'ಕನ್ನಡ'),
    ('gu', 'Gujarati', 'ગુજરાતી'),
    ('mr', 'Marathi', 'मराठी')
ON CONFLICT (code) DO NOTHING;


-- -----------------------------------------------------------------------------
-- TABLE: places - Core placename ontology
-- -----------------------------------------------------------------------------


CREATE TABLE india_post.places (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    uri TEXT UNIQUE,
    administrative_level_id UUID REFERENCES india_post.administrative_level(id),
    district_id UUID REFERENCES india_post.places(id),
    region_id UUID REFERENCES india_post.places(id),  -- state
    country_id UUID REFERENCES india_post.places(id),
    population INTEGER,
    elevation_meters NUMERIC,
    founded DATE,
    location GEOGRAPHY(POINT, 4326),
    geo_shape GEOGRAPHY(POLYGON, 4326),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_places_location ON india_post.places USING GIST(location);
CREATE INDEX idx_places_geo_shape ON india_post.places USING GIST(geo_shape);
CREATE INDEX idx_places_district ON india_post.places(district_id);
CREATE INDEX idx_places_region ON india_post.places(region_id);
CREATE INDEX idx_places_country ON india_post.places(country_id);


-- ##################################################################################
-- TABLE: place_name - Multilingual names for places
-- ##################################################################################


CREATE TABLE india_post.place_name (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    place_id UUID NOT NULL REFERENCES india_post.places(id) ON DELETE CASCADE,
    language_code VARCHAR(10) NOT NULL REFERENCES india_post.language(code),
    name TEXT NOT NULL,
    is_preferred BOOLEAN DEFAULT TRUE,
    source TEXT,
    UNIQUE(place_id, language_code, name)
);

CREATE INDEX idx_place_name_name ON india_post.place_name(name);
CREATE INDEX idx_place_name_lang ON india_post.place_name(language_code);


-- ##################################################################################
-- TRIGGER: auto-update updated_at
-- ##################################################################################


CREATE OR REPLACE FUNCTION india_post.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_places_updated_at
    BEFORE UPDATE ON india_post.places
    FOR EACH ROW
    EXECUTE FUNCTION india_post.update_updated_at_column();


-- ##################################################################################
-- TABLE: india_post.post_office - Raw Indian postal data
-- ##################################################################################


CREATE TABLE india_post.post_office (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    circle TEXT,
    region TEXT,
    division TEXT,
    postoffice TEXT NOT NULL,
    pincode CHAR(6),
    officetype TEXT,
    deliverystatus TEXT,
    district TEXT,
    state TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    location GEOGRAPHY(POINT, 4326),
    subdivision TEXT,
    officeid TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    CONSTRAINT uk_pin_office UNIQUE(pincode, postoffice)
);

-- Indexes
CREATE INDEX idx_post_office_location ON india_post.post_office USING GIST(location);
CREATE INDEX idx_post_office_pincode ON india_post.post_office(pincode);
CREATE INDEX idx_post_office_district ON india_post.post_office(district);
CREATE INDEX idx_post_office_state ON india_post.post_office(state);
CREATE INDEX idx_post_office_name ON india_post.post_office(postoffice);

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION india_post.update_post_office_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_post_office
    BEFORE UPDATE ON india_post.post_office
    FOR EACH ROW
    EXECUTE FUNCTION india_post.update_post_office_updated_at();


-- ##################################################################################
-- VIEW: india_post.placename_union_view - Unified placename + postal data
-- ##################################################################################


CREATE OR REPLACE VIEW india_post.placename_union_view AS

-- From postal data (treated as places)
SELECT
    po.id AS entity_id,
    po.postoffice AS name,
    'en' AS lang,
    'Post Office' AS type,
    po.district AS district,
    po.state AS state,
    po.location,
    ST_X(po.location::geometry) AS lon,
    ST_Y(po.location::geometry) AS lat,
    po.pincode AS identifier,
    'india_post.post_office' AS source
FROM india_post.post_office po
WHERE po.location IS NOT NULL

UNION ALL

-- From core placename ontology
SELECT
    p.id AS entity_id,
    pn.name,
    pn.language_code AS lang,
    al.level_name AS type,
    d.name AS district,
    s.name AS state,
    p.location,
    ST_X(p.location::geometry) AS lon,
    ST_Y(p.location::geometry) AS lat,
    NULL::TEXT AS identifier,
    'india_post.places' AS source
FROM india_post.places p
JOIN india_post.place_name pn ON p.id = pn.place_id
JOIN india_post.administrative_level al ON p.administrative_level_id = al.id
LEFT JOIN india_post.places dist ON p.district_id = dist.id
LEFT JOIN india_post.place_name d ON dist.id = d.place_id AND d.is_preferred
LEFT JOIN india_post.places st ON p.region_id = st.id
LEFT JOIN india_post.place_name s ON st.id = s.place_id AND s.is_preferred
WHERE pn.is_preferred
  AND p.location IS NOT NULL;


-- ##################################################################################
-- INSERT: Seed India as a country
-- ##################################################################################


DO $$
DECLARE india_id UUID;
BEGIN
    SELECT id INTO india_id FROM india_post.places WHERE uri = 'http://example.org/country/india';
    
    IF india_id IS NULL THEN
        INSERT INTO india_post.places (
            id, uri, administrative_level_id, location
        ) VALUES (
            gen_random_uuid(),
            'http://example.org/country/india',
            (SELECT id FROM india_post.administrative_level WHERE level_name = 'Country'),
            ST_SetSRID(ST_MakePoint(82.999997, 23.000000), 4326)::GEOGRAPHY
        ) RETURNING id INTO india_id;

        INSERT INTO india_post.place_name (place_id, language_code, name, is_preferred)
        VALUES (india_id, 'en', 'India', TRUE);
    END IF;
END $$;


-- ##################################################################################
-- INSERT: All Indian post offices from provided data
-- Note: I notice some of the data is malformed or missing coordinates. hence, filtered accordingly.
-- ##################################################################################


INSERT INTO india_post.post_office (
    circle, region, division, postoffice, pincode, officetype, deliverystatus,
    district, state, latitude, longitude, subdivision, officeid
) VALUES
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rajyeswarpur Pt II B.O', '788163', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.5600000, 92.6400000, 'GW5F', 'GW5F-IONBHN'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Sahabad B.O', '788163', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.5600000, 92.6400000, 'GW5F', 'GW5F-F6HFHO'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Vernerpur B.O', '788163', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.5600000, 92.6400000, 'GW5F', 'GW5F-IS2LHP'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Aynakhal Bazar B.O', '788164', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.6500000, 92.5700000, 'GW5G', 'GW5G-OY2RHQ'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Kalachup B.O', '788166', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.5800000, 92.4500000, 'GW5I', 'GW5I-HM4CHV'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Paikan B.O', '788155', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.6800000, 92.5600000, 'GW57', 'GW57-XTAPHW'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rangauti B.O', '788155', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.6800000, 92.5600000, 'GW57', 'GW57-CU3EHX'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rangauti PT II B.O', '788155', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.6800000, 92.5600000, 'GW57', 'GW57-CFCSHY'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Gamaria B.O', '788156', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.6400000, 92.4800000, 'GW58', 'GW58-N3GIHZ'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Srigouri B.O', '788806', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.8700000, 92.5600000, 'GWNA', 'GWNA-VPFXI0'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Umarpur B.O', '788806', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.8700000, 92.5600000, 'GWNA', 'GWNA-CLASI1'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Fakuagram B.O', '788723', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.6800000, 92.3400000, 'GWKZ', 'GWKZ-J3BII2'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chandranathpur B.O', '788817', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.4400000, 92.2900000, 'GWNL', 'GWNL-K1NNI3'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rajpasa B.O', '788701', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.5500000, 92.8200000, 'GWKD', 'GWKD-V8XAI4'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Katabari B.O', '788726', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.4800000, 92.3200000, 'GWL2', 'GWL2-Z451I5'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Lowairpoa B.O', '788726', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.3600000, 92.8500000, 'GWL2', 'GWL2-5VVLI6'),
    ('Assam Circle', 'Dibrugarh Region', 'Dibrugarh Division', 'Itakhuli B.O', '786007', 'BO', 'Delivery', 'DIBRUGARH', 'ASSAM', 27.1000000, 95.2200000, 'GUHJ', 'GUHJ-TCXEY7'),
    ('Assam Circle', 'Dibrugarh Region', 'Dibrugarh Division', 'Medela B.O', '786007', 'BO', 'Delivery', 'DIBRUGARH', 'ASSAM', 27.1000000, 95.2200000, 'GUHJ', 'GUHJ-DGLQY8'),
    ('Assam Circle', 'Dibrugarh Region', 'Dibrugarh Division', 'Dibrual B.O', '786007', 'BO', 'Delivery', 'DIBRUGARH', 'ASSAM', 27.3965999, 94.8714899, 'GUHJ', 'GUHJ-AUCSY9'),
    ('Assam Circle', 'Dibrugarh Region', 'Dibrugarh Division', 'Mancotta B.O', '786003', 'BO', 'Delivery', 'DIBRUGARH', 'ASSAM', 27.4700000, 94.9100000, 'GUHF', 'GUHF-IGVVYA'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Longai B.O', '788728', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.4100000, 92.3000000, 'GWL4', 'GWL4-AWYUI7'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Balipipla Bazar B.O', '788728', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.4100000, 92.3000000, 'GWL4', 'GWL4-GLIBI8'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Purnagar B.O', '788816', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 25.0000000, 92.4600000, 'GWNK', 'GWNK-ITHWI9'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Baroitoli B.O', '788815', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.9700000, 92.5800000, 'GWNJ', 'GWNJ-PIBCIA'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Sadirkhal B.O', '788815', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.9700000, 92.5800000, 'GWNJ', 'GWNJ-KWZIIB'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Shyamnagar B.O', '788720', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.7900000, 92.4100000, 'GWKW', 'GWKW-2364IC'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Singaria Bazar B.O', '788719', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.7200000, 92.3500000, 'GWKV', 'GWKV-D3UQID'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Baropunji B.O', '788781', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.8200000, 92.2900000, 'GWML', 'GWML-HUJXIE'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dasgram B.O', '788722', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.7500000, 92.3500000, 'GWKY', 'GWKY-NNBFIF'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Duttagram B.O', '788722', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.7500000, 92.3500000, 'GWKY', 'GWKY-E8C0IG'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Promodenagar B.O', '788722', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.7500000, 92.3500000, 'GWKY', 'GWKY-RI97IH'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Bhurunga B.O', '788724', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.6100000, 92.3200000, 'GWL0', 'GWL0-PJR6II'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Harinetilla B.O', '788011', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6900000, 92.7500000, 'GW17', 'GW17-GS7CIN'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Algapur B.O', '788101', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8800000, 92.5500000, 'GW3P', 'GW3P-MGGJIO'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dungripar B.O', '788101', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8800000, 92.5500000, 'GW3P', 'GW3P-VCX9IP'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dhanipur B.O', '788120', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6700000, 92.8200000, 'GW48', 'GW48-JBQWIQ'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Baridatara B.O', '781351', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.2701000, 91.2020000, 'GQW7', 'GQW7-NXSCGR'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Burinagar B.O', '781341', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.2135000, 91.2642000, 'GQVX', 'GQVX-EOU5GS'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Angarkata B.O', '781360', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.2648000, 91.2646000, 'GQWG', 'GQWG-74UFGT'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Darangapar B.O', '781360', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.4349000, 91.3329000, 'GQWG', 'GQWG-BR4HGU'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Hawaithang B.O', '788120', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6800000, 92.8300000, 'GW48', 'GW48-3NX6IR'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chhotomanda B.O', '788126', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6912000, 92.8321000, 'GW4E', 'GW4E-OXPLIS'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Singerbond B.O', '788126', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8700000, 92.1451000, 'GW4E', 'GW4E-YD67IT'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Swastipally B.O', '788126', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6900000, 92.4514000, 'GW4E', 'GW4E-C94PIU'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Gurudayalpur B.O', '788114', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.5900000, 92.8410000, 'GW42', 'GW42-256HIZ'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Jibangram B.O', '788114', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.5912000, 92.8400000, 'GW42', 'GW42-NA9LJ0'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Mahadebpur PT I B.O', '788114', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.5900000, 92.8400000, 'GW42', 'GW42-XYFHJ1'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Saptagram B.O', '788114', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.5900000, 92.8400000, 'GW42', 'GW42-YV34J2'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Kanabasti B.O', '788819', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 24.5981000, 92.8543000, 'GWNN', 'GWNN-BLDNJ7'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Nabdi Daolangupu BO', '788819', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.2568070, 92.9999260, 'GWNN', 'GWNN-89N5J8'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Bandarkhal B.O', '788818', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.1100000, 92.8600000, 'GWNM', 'GWNM-PN3KJ9'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Kharthang B.O', '788818', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.1700000, 93.0510000, 'GWNM', 'GWNM-EN45JA'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Harinagar Bazar B.O', '788107', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6800000, 92.7300000, 'GW3V', 'GW3V-3QJQJB'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Kumacherra B.O', '788107', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6500000, 93.0516000, 'GW3V', 'GW3V-IDAKJC'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Nagdirgram B.O', '788121', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6500000, 92.6900000, 'GW49', 'GW49-BO5CJD'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Tolengram B.O', '788108', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.7930800, 93.0045600, 'GW3W', 'GW3W-ZEDKJE'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dezabra B.O', '788832', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 24.5400000, 92.6900000, 'GWO0', 'GWO0-QEVYJF'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Mandardisha B.O', '788832', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.5000000, 93.1100000, 'GWO0', 'GWO0-GPBFJG'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Mupa B.O', '788832', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 24.5400000, 92.6900000, 'GWO0', 'GWO0-R9RBJH'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Kholjang B.O', '788830', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.1800000, 93.1100000, 'GWNY', 'GWNY-K95BJI'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Wardendisha B.O', '788831', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.3000000, 93.1300000, 'GWNZ', 'GWNZ-AQQ6JR'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Relai BO', '788831', 'BO', 'Delivery', 'DIMA HASAO', 'ASSAM', 25.2481130, 93.1113090, 'GWNZ', 'GWNZ-IHS8JS'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Choto Dudpatil Grant B.O', '788002', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8400000, 92.8100000, 'GW0Y', 'GW0Y-2EVRJT'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chhoto Dudpatil PT I B.O', '788002', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8400000, 92.8100000, 'GW0Y', 'GW0Y-5WW3JU'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Ujan Tarapur B.O', '788098', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8300000, 93.0200000, 'GW3M', 'GW3M-6NAOJZ'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Hatikhal Bazar B.O', '788116', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6500000, 92.8900000, 'GW44', 'GW44-MZ5SK0'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rukni B.O', '788116', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6500000, 92.8900000, 'GW44', 'GW44-3WCCK1'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rukni T E B.O', '788116', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6500000, 92.8900000, 'GW44', 'GW44-1Q1YK2'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dhakin Mohonpur B.O', '788119', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.7300000, 92.8900000, 'GW47', 'GW47-9H4NK7'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Jhoragul B.O', '788119', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.7300000, 92.8900000, 'GW47', 'GW47-Z3CKK8'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chirukandi B.O', '788003', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8300000, 92.7300000, 'GW0Z', 'GW0Z-WW6EK9'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Machughat B.O', '788003', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8400000, 92.7500000, 'GW0Z', 'GW0Z-GPKEKA'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Subedar Basti B.O', '788003', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8356000, 92.7500000, 'GW0Z', 'GW0Z-UNLZKB'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Tarapur Khelma B.O', '788003', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8356900, 92.7996300, 'GW0Z', 'GW0Z-Z26YKC'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Gossaipur PT I B.O', '788030', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8800000, 92.8800000, 'GW1Q', 'GW1Q-1291KD'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Lathigram B.O', '788030', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.8800000, 92.8800000, 'GW1Q', 'GW1Q-J6ZSKE'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Ranipukhuri B.O', '784525', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.7110000, 92.9009000, 'GTCD', 'GTCD-7M3QKN'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Chamuapara B.O', '784529', 'BO', 'Delivery', 'DARRANG', 'ASSAM', 26.4724462, 92.0288450, 'GTCH', 'GTCH-7NSSKO'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Howli Mohanpur B.O', '784529', 'BO', 'Delivery', 'DARRANG', 'ASSAM', 26.4251750, 90.9691690, 'GTCH', 'GTCH-TZP9KP'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Rangamati B.O', '784529', 'BO', 'Delivery', 'DARRANG', 'ASSAM', 26.3927246, 91.9749722, 'GTCH', 'GTCH-BN1TKQ'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Pachim Patla B.O', '784526', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.8080500, 91.8797000, 'GTCE', 'GTCE-V4I8KR'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Sastrapara B.O', '784510', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.8381500, 92.4406000, 'GTBY', 'GTBY-ZHZLKS'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Ghograbazar B.O', '784524', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.7208320, 92.2232280, 'GTCC', 'GTCC-WNAGKT'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Kunwari Pukhuri B.O', '784115', 'BO', 'Delivery', 'DARRANG', 'ASSAM', 26.6547373, 78.6377775, 'GT0Z', 'GT0Z-FO2OKU'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Peradhara B.O', '781312', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.4447778, 91.4380000, 'GQV4', 'GQV4-3OR4GZ'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Raumaripathar B.O', '781312', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.4447778, 91.4380000, 'GQV4', 'GQV4-QEX7H0'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Balisatra B.O', '781350', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.1230000, 94.1230000, 'GQW6', 'GQW6-RVY7H1'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Piplibari B.O', '781338', 'BO', 'Delivery', 'NALBARI', 'ASSAM', 26.2243000, 91.1746000, 'GQVU', 'GQVU-C2M4H2'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Bengbari B.O', '784523', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.5943518, 91.9881527, 'GTCB', 'GTCB-0QGLKZ'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Ratanpur B.O', '784523', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.5943518, 91.9881527, 'GTCB', 'GTCB-FTINL0'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Dhopguri B.O', '784528', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.7110300, 92.9009000, 'GTCG', 'GTCG-IATEL1'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Nashanshali B.O', '784528', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.7110300, 92.9009000, 'GTCG', 'GTCG-YX6RL2'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Nalkhamara B.O', '784509', 'BO', 'Delivery', 'UDALGURI', 'ASSAM', 26.7730800, 92.1092000, 'GTBX', 'GTBX-9RVIL7'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Rawanmukh B.O', '784169', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.7110300, 92.9009000, 'GT2H', 'GT2H-Z2QRL8'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Silonigaon B.O', '784101', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.8273500, 92.7834500, 'GT0L', 'GT0L-2D3EL9'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Brahmajan B.O', '784172', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8268813, 93.5180273, 'GT2K', 'GT2K-4KRELA'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Karora B.O', '781381', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.3461300, 91.7282600, 'GQX1', 'GQX1-AWYXEI'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Dobok B.O', '781380', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.3456840, 91.6898280, 'GQX0', 'GQX0-R9B6EJ'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Santipur B.O', '781141', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.1887770, 91.7456380, 'GQQD', 'GQQD-4Z3VEK'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Rangamati B.O', '781122', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.1006600, 91.5051900, 'GQPU', 'GQPU-XWZFEL'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Helemguri B.O', '784172', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8268810, 93.5180270, 'GT2K', 'GT2K-2BU8LB'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Buroi Ghat B.O', '784179', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8661200, 93.4090500, 'GT2R', 'GT2R-16PCLC'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Dipota B.O', '784150', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.6208280, 92.7990140, 'GT1Y', 'GT1Y-SFFGLD'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Aujuli Rangagora B.O', '784103', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.8650579, 92.7837887, 'GT0N', 'GT0N-1GQELE'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Boko Agchia B.O', '781123', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 25.9734700, 91.2290200, 'GQPV', 'GQPV-LDCNEM'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Gohalkona B.O', '781123', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 25.9734700, 91.2290200, 'GQPV', 'GQPV-HY2MEN'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Kinangaon B.O', '781123', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 25.9734700, 91.2290200, 'GQPV', 'GQPV-3XT9EO'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Bakalipara B.O', '781124', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0499700, 91.3929100, 'GQPW', 'GQPW-9TJ7EP'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Uttar Amloga B.O', '784103', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.6208280, 92.7990140, 'GT0N', 'GT0N-QJMGLF'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Batashipur B.O', '784111', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.6208280, 92.7990149, 'GT0V', 'GT0V-HKSILG'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Rangapukhuri B.O', '784501', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7298000, 92.6739000, 'GTBP', 'GTBP-7R5XLH'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Ghogra B.O', '784110', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7015920, 92.4778369, 'GT0U', 'GT0U-45LDLI'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Ghoramara B.O', '781124', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0499700, 91.3929100, 'GQPW', 'GQPW-7Z1NEQ'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Kaimari B.O', '781124', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0499700, 91.3929100, 'GQPW', 'GQPW-9KUQER'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Kuwarpur B.O', '781102', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.2488333, 91.5240555, 'GQPA', 'GQPA-MHHYES'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Ramdia B.O', '781102', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.2488333, 91.5240555, 'GQPA', 'GQPA-FGPFET'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Keherukhanda B.O', '784110', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7015980, 92.4778309, 'GT0U', 'GT0U-MT4ALJ'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Kakila Chariali B.O', '784168', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.6208280, 93.6632800, 'GT2G', 'GT2G-P8WWLK'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Milanpur B.O', '784168', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8817040, 93.6178550, 'GT2G', 'GT2G-QZP8LL'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Simaluguri B.O', '784168', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8817060, 93.6178530, 'GT2G', 'GT2G-RJ3BLM'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Amtala B.O', '781134', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0736110, 91.4286110, 'GQQ6', 'GQQ6-N9CIEU'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Jiakur B.O', '781134', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0736110, 91.4286110, 'GQQ6', 'GQQ6-NU0REV'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Dadara B.O', '781104', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.1455000, 91.3418000, 'GQPC', 'GQPC-CRO4EW'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Tetelia B.O', '781104', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.1455000, 91.3418000, 'GQPC', 'GQPC-Q1DDEX'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Radhamadhabhat B.O', '783131', 'BO', 'Delivery', 'SOUTH SALMARA MANCACHAR', 'ASSAM', NULL, NULL, 'GS9N', 'GS9N-OSAU8T'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Dahela B.O', '783125', 'BO', 'Delivery', 'GOALPARA', 'ASSAM', NULL, NULL, 'GS9H', 'GS9H-HPHB8U'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Matia Bazar B.O', '783125', 'BO', 'Delivery', 'GOALPARA', 'ASSAM', NULL, NULL, 'GS9H', 'GS9H-CSNW8V'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Sutarpara B.O', '783125', 'BO', 'Delivery', 'GOALPARA', 'ASSAM', NULL, NULL, 'GS9H', 'GS9H-I7U28W'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Patpara B.O', '783130', 'BO', 'Delivery', 'GOALPARA', 'ASSAM', NULL, NULL, 'GS9M', 'GS9M-G8038X'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Tengajhar B.O', '781364', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.5841000, 91.7308895, 'GQWK', 'GQWK-NKIMEY'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Betagaon B.O', '781364', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.5841000, 91.7308895, 'GQWK', 'GQWK-0N48EZ'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Dhengargaon B.O', '781125', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0900000, 91.5400000, 'GQPX', 'GQPX-LNZAF0'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Gosaihat B.O', '781125', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0900000, 91.5400000, 'GQPX', 'GQPX-ZQFOF1'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Patakata B.O', '783127', 'BO', 'Delivery', 'SOUTH SALMARA MANCACHAR', 'ASSAM', 25.844317, 89.969316, 'GS9J', 'GS9J-0ZW48Y'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Kokradanga B.O', '783128', 'BO', 'Delivery', 'SOUTH SALMARA MANCACHAR', 'ASSAM', NULL, NULL, 'GS9K', 'GS9K-2AJ68Z'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Muhurirchar B.O', '783128', 'BO', 'Delivery', 'SOUTH SALMARA MANCACHAR', 'ASSAM', NULL, NULL, 'GS9K', 'GS9K-9HU990'),
    ('Assam Circle', 'DivReportingCircle', 'Goalpara Division', 'Nilokhia Pt III BO', '783128', 'BO', 'Delivery', 'SOUTH SALMARA MANCACHAR', 'ASSAM', NULL, NULL, 'GS9K', 'GS9K-0FAC91'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Mukoli Gaon B.O', '784170', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.6542500, 92.8011500, 'GT2I', 'GT2I-P1DKLR'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Solaguri B.O', '784180', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7753699, 92.9350681, 'GT2S', 'GT2S-4TBILS'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Pulisomoni No.1 B.O', '784178', 'BO', 'Delivery', 'Biswanath', 'ASSAM', 26.8498500, 92.5678500, 'GT2Q', 'GT2Q-AHAELT'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Bansbera B.O', '784506', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.8143740, 92.5941159, 'GTBU', 'GTBU-C4LZLU'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Sikarhati B.O', '781125', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.0900000, 91.5400000, 'GQPX', 'GQPX-PT94F2'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Alupati B.O', '781127', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 25.2627000, 92.1817000, 'GQPZ', 'GQPZ-Q9WQF3'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Hekra B.O', '781127', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 25.2627000, 92.1817000, 'GQPZ', 'GQPZ-4QBEF4'),
    ('Assam Circle', 'DivReportingCircle', 'Guwahati Division', 'Mahtoli B.O', '781136', 'BO', 'Delivery', 'KAMRUP', 'ASSAM', 26.2302000, 91.7102000, 'GQQ8', 'GQQ8-1EO3F5'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Kailajuli B.O', '784505', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.9091800, 92.6526500, 'GTBT', 'GTBT-V9ZRLZ'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Urahiloga B.O', '784505', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.9091800, 92.6526500, 'GTBT', 'GTBT-Y7QFM0'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Borsola B.O', '784117', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7009195, 92.5173105, 'GT11', 'GT11-IQO6M1'),
    ('Assam Circle', 'DivReportingCircle', 'Darrang Division', 'Fatasimalugaon B.O', '784117', 'BO', 'Delivery', 'SONITPUR', 'ASSAM', 26.7063777, 92.5420659, 'GT11', 'GT11-FW5TM2'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Pechaala B.O', '788734', 'BO', 'Delivery', 'KARIMGANJ', 'ASSAM', 24.5487900, 92.4276800, 'GWLA', 'GWLA-EDM8H3'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Rosekandi B.O', '788117', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6800000, 92.7300000, 'GW45', 'GW45-PB6CH4'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Sahapur B.O', '788117', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6800000, 92.7300000, 'GW45', 'GW45-5CU0H5'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Taranathpur B.O', '788117', 'BO', 'Delivery', 'CACHAR', 'ASSAM', 24.6800000, 92.7300000, 'GW45', 'GW45-TM06H6'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Bhotanta Mohitara B.O', '781328', 'BO', 'Delivery', 'Bajali', 'ASSAM', NULL, NULL, 'GQVK', 'GQVK-M1OKFA'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Mainamata B.O', '781315', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102500, 'GQV7', 'GQV7-KM62FB'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Bhogerpar B.O', '781309', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3002400, 91.0725700, 'GQV1', 'GQV1-R1N1FC'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Palhaji B.O', '781309', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3002400, 91.0725700, 'GQV1', 'GQV1-2CBOFD'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Kurobaha B.O', '781352', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102500, 'GQW8', 'GQW8-ZPNVFE'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Khangra B.O', '781305', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2794500, 91.1562800, 'GQUX', 'GQUX-G9Z0FF'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Ambari B.O', '781316', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.4285277, 90.9693611, 'GQV8', 'GQV8-B8XFFG'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Ghilajari B.O', '781316', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.4285277, 90.9693611, 'GQV8', 'GQV8-CRBZFH'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Charcharia B.O', '781319', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2131000, 90.5215000, 'GQVB', 'GQVB-YYXUFM'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Sawpur B.O', '781319', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2131000, 90.5215000, 'GQVB', 'GQVB-BV7CFN'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Kamardisa B.O', '781330', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.3291389, 91.0102500, 'GQVM', 'GQVM-3YBWFO'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Lowkata B.O', '781330', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.3291389, 91.0102500, 'GQVM', 'GQVM-KQC9FP'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Kadomtola B.O', '781308', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3171000, 91.0051000, 'GQV0', 'GQV0-RXWLFQ'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Manikpur B.O', '781308', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3171000, 91.0051000, 'GQV0', 'GQV0-13GLFR'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Garartari B.O', '781311', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102499, 'GQV3', 'GQV3-D5IKFS'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Raoli B.O', '781311', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102500, 'GQV3', 'GQV3-ENMJFT'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Gobindapur B.O', '781326', 'BO', 'Delivery', 'Bajali', 'ASSAM', 26.3024000, 91.1412000, 'GQVI', 'GQVI-Y98FFU'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Bamakhata B.O', '781325', 'BO', 'Delivery', 'Bajali', 'ASSAM', 26.4999166, 91.1787222, 'GQVH', 'GQVH-SBZLFV'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Odalguri B.O', '781325', 'BO', 'Delivery', 'Bajali', 'ASSAM', 26.4999166, 91.1787222, 'GQVH', 'GQVH-89FPFW'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Bhatkuchi B.O', '781314', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102500, 'GQV6', 'GQV6-0AP0FX'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Jarabari B.O', '781314', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.3291389, 91.0102500, 'GQV6', 'GQV6-RRUDFY'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Kardoiguri B.O', '781318', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2953000, 91.0432000, 'GQVA', 'GQVA-T4JYFZ'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Rupahi B.O', '781320', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2953000, 91.0432000, 'GQVC', 'GQVC-SV0LG0'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Chamuagati B.O', '781320', 'BO', 'Delivery', 'BARPETA', 'ASSAM', 26.2953000, 91.0432000, 'GQVC', 'GQVC-PAWHG1'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Murmela B.O', '781346', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.3129000, 91.2106000, 'GQW2', 'GQW2-EROZGA'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Bennabari B.O', '781333', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.2809000, 91.2549000, 'GQVP', 'GQVP-MGTKGB'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Dalbari B.O', '781333', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.2809000, 91.2549000, 'GQVP', 'GQVP-3IFRGC'),
    ('Assam Circle', 'DivReportingCircle', 'Nalbari Division', 'Pub Baramchari B.O', '781333', 'BO', 'Delivery', 'BAKSA', 'ASSAM', 26.2809000, 91.2549000, 'GQVP', 'GQVP-FYHOGD'),
    ('Assam Circle', 'Dibrugarh Region', 'Nagaon Division', 'Uttar Garanjan B.O', '782128', 'BO', 'Delivery', 'NAGAON', 'ASSAM', 26.3486944, 92.7005000, 'GRHS', 'GRHS-TP2U3B'),
    ('Assam Circle', 'Dibrugarh Region', 'Nagaon Division', 'Uttar Khatowal B.O', '782128', 'BO', 'Delivery', 'NAGAON', 'ASSAM', 26.3486944, 92.7005000, 'GRHS', 'GRHS-0VA13C'),
    ('Assam Circle', 'Dibrugarh Region', 'Sibsagar Division', 'Goriajan B.O', '785611', 'BO', 'Delivery', 'GOLAGHAT', 'ASSAM', 26.4008000, 93.4834000, 'GU6J', 'GU6J-XZ953D'),
    ('Assam Circle', 'Dibrugarh Region', 'Sibsagar Division', 'Alami Chapori BO', '785611', 'BO', 'Delivery', 'GOLAGHAT', 'ASSAM', 26.7363180, 93.8647820, 'GU6J', 'GU6J-JD5A3E'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Gharmura Bus Stand B.O', '788162', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.5500000, 92.5900000, 'GW5E', 'GW5E-CRWVHB'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Algapur PT II B.O', '788150', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.7600000, 92.5900000, 'GW52', 'GW52-9QQEHC'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chandipur B.O', '788150', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.7600000, 92.5900000, 'GW52', 'GW52-HH4HHD'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Matirgram B.O', '788150', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.7600000, 92.5900000, 'GW52', 'GW52-ZTATHE'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Chiparsangam B.O', '788801', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 28.6100000, 80.0800000, 'GWN5', 'GWN5-KZ7RHF'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Dholai South B.O', '788161', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.4500000, 92.5500000, 'GW5D', 'GW5D-77UCHG'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Katlacherra Bazar B.O', '788161', 'BO', 'Non Delivery', 'HAILAKANDI', 'ASSAM', 24.4500000, 92.5500000, 'GW5D', 'GW5D-Z7DMHH'),
    ('Assam Circle', 'DivReportingCircle', 'Cachar Division', 'Telkatta B.O', '788161', 'BO', 'Delivery', 'HAILAKANDI', 'ASSAM', 24.4500000, 92.5500000, 'GW5D', 'GW5D-U31EHI');
    -- Add more if needed


-- ##################################################################################
-- UPDATE: Populate location from latitude and longitude
-- ##################################################################################


UPDATE india_post.post_office
SET location = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::GEOGRAPHY
WHERE latitude IS NOT NULL
  AND longitude IS NOT NULL
  AND longitude BETWEEN -180 AND 180
  AND latitude BETWEEN -90 AND 90;


-- ##################################################################################
-- SYNC: Promote post offices into placename ontology (optional)
-- Creates unified semantic graph
-- ##################################################################################


-- Sync states
INSERT INTO india_post.places (id, uri, administrative_level_id, country_id)
SELECT DISTINCT
    gen_random_uuid(),
    'http://example.org/state/' || LOWER(REPLACE(UPPER(TRIM(state)), ' ', '_')),
    (SELECT id FROM india_post.administrative_level WHERE level_name = 'State'),
    (SELECT id FROM india_post.places WHERE uri = 'http://example.org/country/india')
FROM india_post.post_office po
WHERE NOT EXISTS (
    SELECT 1 FROM india_post.place_name pn
    JOIN india_post.places p ON pn.place_id = p.id
    WHERE LOWER(pn.name) = LOWER(TRIM(po.state))
      AND pn.language_code = 'en'
)
ON CONFLICT DO NOTHING;

-- Sync districts under states
INSERT INTO india_post.places (id, uri, administrative_level_id, region_id)
SELECT DISTINCT
    gen_random_uuid(),
    'http://example.org/district/' || LOWER(REPLACE(UPPER(TRIM(po.district)), ' ', '_')),
    (SELECT id FROM india_post.administrative_level WHERE level_name = 'District'),
    st.id
FROM india_post.post_office po
JOIN india_post.places st ON st.uri = 'http://example.org/state/' || LOWER(REPLACE(UPPER(TRIM(po.state)), ' ', '_'))
WHERE NOT EXISTS (
    SELECT 1 FROM india_post.place_name pn
    JOIN india_post.places p ON pn.place_id = p.id
    WHERE LOWER(pn.name) = LOWER(TRIM(po.district))
      AND pn.language_code = 'en'
)
ON CONFLICT DO NOTHING;

-- Sync post offices
INSERT INTO india_post.places (id, uri, administrative_level_id, district_id, region_id, country_id, location)
SELECT
    po.id,
    'http://example.org/postoffice/' || po.pincode || '/' || MD5(po.postoffice),
    (SELECT id FROM india_post.administrative_level WHERE level_name = 'Post Office'),
    d.id,
    st.id,
    (SELECT id FROM india_post.places WHERE uri = 'http://example.org/country/india'),
    po.location
FROM india_post.post_office po
LEFT JOIN india_post.places d ON d.uri = 'http://example.org/district/' || LOWER(REPLACE(UPPER(TRIM(po.district)), ' ', '_'))
LEFT JOIN india_post.places st ON st.uri = 'http://example.org/state/' || LOWER(REPLACE(UPPER(TRIM(po.state)), ' ', '_'))
WHERE NOT EXISTS (SELECT 1 FROM india_post.places p WHERE p.id = po.id)
ON CONFLICT (id) DO NOTHING;

-- Insert names
INSERT INTO india_post.place_name (place_id, language_code, name, is_preferred)
SELECT po.id, 'en', po.postoffice, TRUE
FROM india_post.post_office po
WHERE NOT EXISTS (
    SELECT 1 FROM india_post.place_name pn
    WHERE pn.place_id = po.id
      AND pn.name = po.postoffice
      AND pn.language_code = 'en'
)
ON CONFLICT (place_id, language_code, name) DO NOTHING;


--##################################################################################
-- FINALIZE: Analyze tables for performance
-- ##################################################################################


ANALYZE india_post.post_office;
ANALYZE india_post.places;
ANALYZE india_post.place_name;


-- ##################################################################################
-- FUNCTION: india_post.places_to_jsonld
-- Converts a single place (from india_post.places) into JSON-LD
-- ##################################################################################

CREATE OR REPLACE FUNCTION india_post.places_to_jsonld()
RETURNS TABLE(jsonld JSONB)
AS $$
BEGIN
    RETURN QUERY
    SELECT jsonb_build_object(
        '@context', jsonb_build_object(
            'rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
            'rdfs', 'http://www.w3.org/2000/01/rdf-schema#',
            'schema', 'https://schema.org/',
            'placename', 'http://example.org/placename-ontology#',
            'geo', 'http://www.opengis.net/ont/geosparql#',
            'dcterms', 'http://purl.org/dc/terms/'
        ),
        '@id', p.uri,
        '@type', 'schema:Place',
        'schema:name', COALESCE(pn.name, ''),
        'placename:administrativeLevel', al.level_name,
        'schema:containedInPlace', jsonb_build_object(
            '@id', CASE WHEN st.uri IS NOT NULL THEN st.uri ELSE NULL END,
            'schema:name', st_name.name,
            '@type', 'schema:AdministrativeArea'
        ),
        'schema:address', jsonb_build_object(
            'schema:addressLocality', d_name.name,
            'schema:addressRegion', st_name.name,
            'schema:postalCode', po.pincode,
            'schema:addressCountry', 'India'
        ),
        'schema:geo', CASE WHEN p.location IS NOT NULL THEN jsonb_build_object(
            '@type', 'schema:GeoCoordinates',
            'schema:latitude', ST_Y(p.location::geometry),
            'schema:longitude', ST_X(p.location::geometry)
        ) ELSE NULL END,
        'dcterms:identifier', jsonb_build_array(
            jsonb_build_object('type', 'pincode', 'value', po.pincode),
            jsonb_build_object('type', 'officeid', 'value', po.officeid)
        ),
        'placename:dataSource', 'india_post.post_office'
    ) AS jsonld
    FROM india_post.places p
    JOIN india_post.place_name pn ON p.id = pn.place_id AND pn.is_preferred
    JOIN india_post.administrative_level al ON p.administrative_level_id = al.id
    LEFT JOIN india_post.place_name d_name ON p.district_id = d_name.place_id AND d_name.is_preferred
    LEFT JOIN india_post.places st ON p.region_id = st.id
    LEFT JOIN india_post.place_name st_name ON st.id = st_name.place_id AND st_name.is_preferred
    LEFT JOIN india_post.post_office po ON p.id = po.id;
END;
$$ LANGUAGE plpgsql STABLE;


-- -----------------------------------------------------------------------------
-- VIEW: india_post.placename_jsonld_view
-- Exports all places as an array of JSON-LD objects
-- Suitable for API responses or bulk export
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW india_post.placename_jsonld_view AS
SELECT
    jsonb_build_object(
        '@context', jsonb_build_object(
            'rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
            'rdfs', 'http://www.w3.org/2000/01/rdf-schema#',
            'schema', 'https://schema.org/',
            'placename', 'http://example.org/placename-ontology#',
            'geo', 'http://www.opengis.net/ont/geosparql#',
            'dcterms', 'http://purl.org/dc/terms/'
        ),
        '@graph', jsonb_agg(
            jsonb_build_object(
                '@id', p.uri,
                '@type', 'schema:Place',
                'schema:name', pn.name,
                'placename:administrativeLevel', al.level_name,
                'schema:containedInPlace', jsonb_build_object(
                    '@id', st.uri,
                    'schema:name', st_name.name,
                    '@type', 'schema:AdministrativeArea'
                ),
                'schema:address', jsonb_build_object(
                    'schema:addressLocality', d_name.name,
                    'schema:addressRegion', st_name.name,
                    'schema:postalCode', po.pincode,
                    'schema:addressCountry', 'India'
                ),
                'schema:geo', CASE WHEN p.location IS NOT NULL THEN jsonb_build_object(
                    '@type', 'schema:GeoCoordinates',
                    'schema:latitude', round(ST_Y(p.location::geometry)::NUMERIC, 6),
                    'schema:longitude', round(ST_X(p.location::geometry)::NUMERIC, 6)
                ) ELSE NULL END,
                'dcterms:identifier', jsonb_build_array(
                    jsonb_build_object('type', 'pincode', 'value', po.pincode),
                    jsonb_build_object('type', 'officeid', 'value', po.officeid)
                ),
                'placename:dataSource', 'india_post.post_office'
            )
        )
    ) AS jsonld
FROM india_post.places p
JOIN india_post.place_name pn ON p.id = pn.place_id AND pn.is_preferred
JOIN india_post.administrative_level al ON p.administrative_level_id = al.id
LEFT JOIN india_post.place_name d_name ON p.district_id = d_name.place_id AND d_name.is_preferred
LEFT JOIN india_post.places st ON p.region_id = st.id
LEFT JOIN india_post.place_name st_name ON st.id = st_name.place_id AND st_name.is_preferred
LEFT JOIN india_post.post_office po ON p.id = po.id
WHERE p.location IS NOT NULL
  AND pn.language_code = 'en';


-- ##############################################################################################################################################################################################
-- Execution 
SELECT * FROM india_post.placename_jsonld_view;

-- SELECT jsonb_pretty(india_post.places_to_jsonld.jsonld) FROM india_post.places_to_jsonld() WHERE jsonld @> '{"schema": {"postalCode": ""}}';

-- ##################################################################################
-- FUNCTION: india_post.places_to_turtle()

-- ##################################################################################
CREATE OR REPLACE FUNCTION india_post.places_to_turtle()
RETURNS TEXT AS $$
DECLARE
    ttl TEXT := '';
    rec RECORD;
    state_safe_name TEXT;
BEGIN
    -- Initialize TTL with prefixes
    ttl := '@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .' || E'\n';
    ttl := ttl || '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .' || E'\n';
    ttl := ttl || '@prefix schema: <https://schema.org/> .' || E'\n';
    ttl := ttl || '@prefix geo: <http://www.opengis.net/ont/geosparql#> .' || E'\n';
    ttl := ttl || '@prefix placename: <http://example.org/placename-ontology#> .' || E'\n';
    ttl := ttl || '@prefix dcterms: <http://purl.org/dc/terms/> .' || E'\n';
    ttl := ttl || '@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .' || E'\n\n';

    FOR rec IN
        SELECT
            po.pincode,
            REPLACE(po.postoffice, ' ', '_') AS safe_name,
            po.officeid,
            po.deliverystatus,
            TRIM(po.district) AS district,
            TRIM(po.state) AS state,
            ROUND(ST_Y(p.location::geometry)::NUMERIC, 6) AS lat,
            ROUND(ST_X(p.location::geometry)::NUMERIC, 6) AS lon
        FROM india_post.post_office po
        JOIN india_post.places p ON po.id = p.id
        WHERE po.latitude IS NOT NULL
          AND po.longitude IS NOT NULL
        LIMIT 100
    LOOP
        -- Sanitize identifiers
        state_safe_name := LOWER(REPLACE(rec.state, ' ', '_'));

        -- Add state definition only once
        EXECUTE '
            SELECT COUNT(*) FROM (SELECT ''x'' WHERE $1 LIKE ''%<state/' || state_safe_name || '>%'' LIMIT 1) AS t'
            INTO ttl
            USING ttl;

        IF ttl = 0 THEN
            ttl := ttl || E'<state/' || state_safe_name || E'>\n';
            ttl := ttl || E'    rdf:type schema:AdministrativeArea ;\n';
            ttl := ttl || E'    schema:name "' || rec.state || E'"@en ;\n';
            ttl := ttl || E'    placename:administrativeLevel "State" .\n\n';
        END IF;

        -- Add post office
        ttl := ttl || E'<' || rec.pincode || '-' || rec.safe_name || E'>\n';
        ttl := ttl || E'    rdf:type schema:PostOffice ;\n';
        ttl := ttl || E'    schema:name "' || rec.postoffice || E'"@en ;\n';
        ttl := ttl || E'    schema:postalCode "' || rec.pincode || E'" ;\n';
        ttl := ttl || E'    schema:officeId "' || rec.officeid || E'" ;\n';
        ttl := ttl || E'    schema:deliveryStatus "' || rec.deliverystatus || E'" ;\n';
        ttl := ttl || E'    schema:address [\n';
        ttl := ttl || E'        rdf:type schema:PostalAddress ;\n';
        ttl := ttl || E'        schema:addressLocality "' || rec.district || E'" ;\n';
        ttl := ttl || E'        schema:addressRegion "' || rec.state || E'" ;\n';
        ttl := ttl || E'        schema:addressCountry "India"\n';
        ttl := ttl || E'    ] ;\n';
        ttl := ttl || E'    schema:containedInPlace <state/' || state_safe_name || E'> ;\n';
        ttl := ttl || E'    schema:geo [\n';
        ttl := ttl || E'        rdf:type schema:GeoCoordinates ;\n';
        ttl := ttl || E'        schema:latitude "' || rec.lat || E'"^^xsd:float ;\n';
        ttl := ttl || E'        schema:longitude "' || rec.lon || E'"^^xsd:float\n';
        ttl := ttl || E'    ] ;\n';
        ttl := ttl || E'    placename:dataSource "india_post_ontology" .\n\n';
    END LOOP;

    RETURN ttl;
END;
$$ LANGUAGE plpgsql;


--##################################################################################
-- Todo Awase: Integrate with Apache Jena full for all countries getting accurate licensed data- Expensive
-- using the open source data and improvising it 
-- ##################################################################################
